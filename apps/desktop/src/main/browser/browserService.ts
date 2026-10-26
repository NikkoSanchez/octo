import { app, BrowserWindow, session, shell, WebContentsView, type Session, type WebContents } from "electron";
import { makeBrowserAnnotation, newID, type BrowserAnnotation } from "@octo/core";
import {
  browserURL, browserViewport, ZOOM_LEVELS, type BrowserAppearance, type BrowserBounds, type BrowserDevice, type BrowserEvent, type BrowserState,
} from "../../shared/browser";
import { ANNOTATION_SCRIPT, ANNOTATION_WORLD } from "./annotationScript";

/** Non-private tabs share one persistent profile, separate from the app's own session. */
const DEFAULT_PARTITION = "persist:octo-browser";
const ALLOWED_SCHEMES = new Set(["http:", "https:", "about:", "data:", "blob:"]);

export interface BrowserHost {
  window(): BrowserWindow | undefined;
  shortcut?(input: { code: string; meta: boolean; control: boolean; shift: boolean; alt: boolean }, type: string): boolean;
  emit(event: BrowserEvent): void;
  /** The saved address and privacy of a panel tab. */
  tab(projectID: string, id: string): { address?: string; isPrivate: boolean } | undefined;
  recordAddress(projectID: string, id: string, address: string): void;
  openTab(projectID: string, id: string, isPrivate: boolean): void;
  closeTab(projectID: string, id: string): void;
  attachAnnotation(annotation: BrowserAnnotation, screenshot: Buffer | undefined, projectID: string): void;
  attachScreenshot(data: Buffer, projectID: string): void;
}

/** Chromium's own agent, without Electron's and the app's tokens, so sites see an ordinary Chrome. */
function chromeUserAgent(agent: string): string {
  return agent.replace(/\s(Electron|octo[-\w]*|Octo[\w ]*?)\/\S+/g, "").replace(/\s{2,}/g, " ");
}

class BrowserTab {
  readonly view: WebContentsView;
  state: BrowserState;
  private pendingAddress: string | undefined;
  private fitScale = 1;
  private visible = false;
  private bounds: BrowserBounds = { x: 0, y: 0, width: 0, height: 0 };
  private window: BrowserWindow | undefined;
  private attachedTo: BrowserWindow | undefined;
  private annotationRun = 0;

  constructor(readonly id: string, readonly projectID: string, readonly profile: Session, isPrivate: boolean,
              private readonly service: BrowserService, existing?: WebContents) {
    this.view = existing
      ? new WebContentsView({ webContents: existing })
      : new WebContentsView({ webPreferences: { session: profile, sandbox: true, contextIsolation: true, nodeIntegration: false, webviewTag: false, spellcheck: true } });
    this.view.setVisible(false);
    this.state = {
      id, projectID, address: "", title: "", canGoBack: false, canGoForward: false, loading: false, annotating: false, zoom: 1,
      appearance: "system", landscape: false, detached: false, isPrivate, restoring: false,
    };
    this.observe();
  }

  get contents(): WebContents { return this.view.webContents; }

  private publish(change: Partial<BrowserState> = {}): void {
    Object.assign(this.state, change);
    const contents = this.contents;
    if (!contents.isDestroyed()) {
      this.state.canGoBack = contents.navigationHistory.canGoBack();
      this.state.canGoForward = contents.navigationHistory.canGoForward();
    }
    this.service.emit({ type: "state", state: { ...this.state } });
  }

  private observe(): void {
    const contents = this.contents;
    contents.setUserAgent(chromeUserAgent(contents.getUserAgent()));
    contents.on("page-title-updated", (_event, title) => {
      this.window?.setTitle(title || "Browser");
      this.publish({ title });
    });
    const navigated = (url: string) => {
      if (url && url !== "about:blank") {
        this.service.host.recordAddress(this.projectID, this.id, url);
        this.publish({ url, address: url });
      } else this.publish();
    };
    contents.on("did-navigate", (_event, url) => { this.publish({ annotating: false, error: undefined }); navigated(url); });
    contents.on("did-navigate-in-page", (_event, url, isMainFrame) => { if (isMainFrame) navigated(url); });
    contents.on("before-input-event", (event, input) => {
      if (this.service.host.shortcut?.(input, input.type)) { event.preventDefault(); return; }
      if ((process.platform === "darwin" ? input.meta : input.control) && !input.alt && !input.shift && input.code === "KeyL") {
        event.preventDefault();
        if (input.type === "keyDown") { this.service.host.window()?.webContents.focus(); this.service.emit({ type: "focusAddress", id: this.id }); }
      }
    });
    contents.on("did-start-loading", () => this.publish({ loading: true }));
    contents.on("did-stop-loading", () => this.publish({ loading: false }));
    contents.on("did-fail-load", (_event, code, description, _url, isMainFrame) => {
      // -3 is ERR_ABORTED: a navigation replaced by another or stopped by the user.
      if (isMainFrame && code !== -3) this.publish({ error: description || `The page could not load (${code}).` });
    });
    contents.on("will-navigate", (event) => this.policy(event, event.url));
    contents.on("will-redirect", (event) => this.policy(event, event.url));
    contents.on("will-attach-webview", (event) => event.preventDefault());
    // Pop-ups and target=_blank links open as tabs that keep window.opener, so sign-in pop-ups work.
    contents.setWindowOpenHandler(({ url }) => {
      let scheme = "";
      try { scheme = new URL(url).protocol; } catch { /* invalid */ }
      if (scheme && !ALLOWED_SCHEMES.has(scheme)) { this.requestExternal(url); return { action: "deny" }; }
      return {
        action: "allow",
        createWindow: (options) => {
          // Electron passes the pop-up's prepared contents in the options so it keeps window.opener.
          const prepared = (options as { webContents?: WebContents }).webContents;
          const child = this.service.adopt(this.projectID, this.profile, this.state.isPrivate, prepared);
          return child.contents;
        },
      };
    });
    // window.close() from the page.
    contents.on("destroyed", () => { if (this.service.owns(this)) this.service.host.closeTab(this.projectID, this.id); });
    contents.on("render-process-gone", (_event, details) => {
      if (details.reason !== "clean-exit") this.publish({ error: "This page stopped unexpectedly. Reload to try again." });
    });
  }

  /** Other schemes, such as app links, leave the browser only after the user confirms which app opens them. */
  private policy(event: { preventDefault(): void }, url: string): void {
    let scheme = "";
    try { scheme = new URL(url).protocol; } catch { event.preventDefault(); return; }
    if (ALLOWED_SCHEMES.has(scheme)) return;
    event.preventDefault();
    this.requestExternal(url);
  }

  private requestExternal(url: string): void {
    let scheme: string;
    try { scheme = new URL(url).protocol.replace(/:$/, "").toLowerCase(); } catch { return; }
    if (!scheme || scheme === "javascript" || scheme === "file") return;
    const application = app.getApplicationNameForProtocol(url);
    if (!application) { this.publish({ error: `No app on this computer opens ${scheme}: links.` }); return; }
    this.publish({ pendingExternal: { url, application: application.replace(/\.app$/, "") } });
  }

  confirmExternal(open: boolean): void {
    const link = this.state.pendingExternal;
    this.state.pendingExternal = undefined;
    if (open && link) void shell.openExternal(link.url);
    this.publish();
  }

  // MARK: Placement

  attach(window: BrowserWindow): void {
    if (this.attachedTo === window || this.state.detached) return;
    this.attachedTo?.contentView.removeChildView(this.view);
    window.contentView.addChildView(this.view);
    this.attachedTo = window;
    this.apply();
  }

  setBounds(bounds: BrowserBounds, fitScale: number): void {
    this.bounds = bounds;
    if (Number.isFinite(fitScale) && fitScale > 0 && fitScale !== this.fitScale) { this.fitScale = fitScale; this.applyZoom(); }
    this.apply();
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    this.apply();
    if (visible && this.pendingAddress) this.open(this.pendingAddress);
  }

  private apply(): void {
    if (this.state.detached) return;
    const { x, y, width, height } = this.bounds;
    const show = this.visible && width > 0 && height > 0;
    if (show) this.view.setBounds({ x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) });
    this.view.setVisible(show);
  }

  focus(): void { if (this.visible) this.contents.focus(); }

  // MARK: Navigation

  open(input: string): void {
    const url = browserURL(input);
    if (!url) return;
    this.pendingAddress = undefined;
    this.publish({ address: url, error: undefined, restoring: false });
    this.contents.loadURL(url).catch(() => { /* reported by did-fail-load */ });
  }

  restore(address: string): void { this.pendingAddress = address; this.publish({ address, restoring: true }); }

  back(): void { this.contents.navigationHistory.goBack(); }
  forward(): void { this.contents.navigationHistory.goForward(); }
  reload(): void { if (this.state.loading) this.contents.stop(); else { this.publish({ error: undefined }); this.contents.reload(); } }
  /** Revalidates every resource instead of using cached copies. */
  hardReload(): void { this.publish({ error: undefined }); this.contents.reloadIgnoringCache(); }
  stop(): void { this.contents.stop(); }
  openExternally(): void { if (this.state.url) void shell.openExternal(this.state.url); }
  openDevTools(): void { this.contents.openDevTools({ mode: "detach" }); }

  setZoom(direction: "in" | "out" | "reset"): void {
    const zoom = this.state.zoom;
    const next = direction === "reset" ? 1
      : direction === "in" ? ZOOM_LEVELS.find((l) => l > zoom + 0.001) ?? zoom
      : [...ZOOM_LEVELS].reverse().find((l) => l < zoom - 0.001) ?? zoom;
    this.publish({ zoom: next });
    this.applyZoom();
  }

  private applyZoom(): void { if (!this.contents.isDestroyed()) this.contents.setZoomFactor(this.state.zoom * this.fitScale); }

  setDevice(device: BrowserDevice | undefined, landscape: boolean): void {
    this.publish({ device, landscape });
    if (!device) { this.fitScale = 1; this.applyZoom(); }
  }

  /** The page's `prefers-color-scheme`, emulated per tab. */
  async setAppearance(appearance: BrowserAppearance): Promise<void> {
    this.publish({ appearance });
    const debug = this.contents.debugger;
    try {
      if (appearance === "system") {
        if (debug.isAttached()) { await debug.sendCommand("Emulation.setEmulatedMedia", { features: [] }); debug.detach(); }
        return;
      }
      if (!debug.isAttached()) debug.attach("1.3");
      await debug.sendCommand("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: appearance }] });
    } catch (error) {
      this.publish({ error: `Couldn't change this page's appearance: ${(error as Error).message}` });
    }
  }

  // MARK: Annotation

  async annotate(): Promise<void> {
    if (!this.state.url) return;
    if (this.state.annotating) {
      this.annotationRun += 1;
      this.publish({ annotating: false });
      await this.contents.executeJavaScriptInIsolatedWorld(ANNOTATION_WORLD, [{ code: ANNOTATION_SCRIPT + "window.__octoAnnotate.stop();" }]).catch(() => undefined);
      return;
    }
    const run = ++this.annotationRun;
    this.publish({ annotating: true });
    let body: unknown;
    try {
      body = await this.contents.executeJavaScriptInIsolatedWorld(ANNOTATION_WORLD, [{ code: ANNOTATION_SCRIPT + "window.__octoAnnotate.start();" }], true);
    } catch {
      if (run === this.annotationRun) this.publish({ annotating: false, error: "This page does not allow annotation." });
      return;
    }
    if (run !== this.annotationRun) return;
    this.publish({ annotating: false });
    const annotation = this.decodeAnnotation(body);
    if (!annotation) return;
    const screenshot = await this.capture(annotation.rect);
    this.service.host.attachAnnotation(annotation, screenshot, this.projectID);
  }

  private decodeAnnotation(body: unknown): BrowserAnnotation | undefined {
    if (!body || typeof body !== "object") return undefined;
    const value = body as Record<string, unknown>;
    if (value.kind !== "element" && value.kind !== "region") return undefined;
    const number = (object: unknown, key: string) => {
      const n = (object as Record<string, unknown> | undefined)?.[key];
      return typeof n === "number" && Number.isFinite(n) ? n : 0;
    };
    const text = (key: string) => (typeof value[key] === "string" ? value[key] as string : "");
    // The page reports its own URL and title; the tab's values are used instead.
    return makeBrowserAnnotation({
      kind: value.kind, url: this.state.url ?? "", pageTitle: this.state.title,
      selector: text("selector"), element: text("element"), text: text("text"), html: text("html"),
      rect: { x: number(value.rect, "x"), y: number(value.rect, "y"), width: number(value.rect, "width"), height: number(value.rect, "height") },
      viewport: { width: number(value.viewport, "width"), height: number(value.viewport, "height") },
    });
  }

  /** `rect` is in CSS pixels relative to the viewport; none captures the visible page. */
  async capture(rect?: BrowserAnnotation["rect"]): Promise<Buffer | undefined> {
    try {
      if (!rect) return (await this.contents.capturePage()).toPNG();
      const scale = this.contents.getZoomFactor();
      const size = this.view.getBounds();
      const x = Math.max(0, Math.floor(rect.x * scale - 6)), y = Math.max(0, Math.floor(rect.y * scale - 6));
      const width = Math.min(size.width - x, Math.ceil(rect.width * scale + 12)), height = Math.min(size.height - y, Math.ceil(rect.height * scale + 12));
      if (width < 2 || height < 2) return undefined;
      return (await this.contents.capturePage({ x, y, width, height })).toPNG();
    } catch { return undefined; }
  }

  // MARK: Window

  /** Moves the live page into its own window; closing that window returns it to the panel. */
  openInWindow(): void {
    if (this.window) { this.window.focus(); return; }
    const window = new BrowserWindow({ width: 1100, height: 800, title: this.state.title || "Browser", show: false });
    this.attachedTo?.contentView.removeChildView(this.view);
    this.attachedTo = undefined;
    window.contentView.addChildView(this.view);
    const fill = () => { const [width, height] = window.getContentSize(); this.view.setBounds({ x: 0, y: 0, width: width ?? 0, height: height ?? 0 }); };
    fill();
    this.view.setVisible(true);
    window.on("resize", fill);
    window.on("closed", () => {
      this.window = undefined;
      this.publish({ detached: false });
      const main = this.service.host.window();
      if (main && !this.contents.isDestroyed()) this.attach(main);
    });
    this.window = window;
    this.publish({ detached: true });
    window.show();
  }

  returnFromWindow(): void { this.window?.close(); }

  /** Ends the page. The tab is not reused afterwards. */
  close(): void {
    this.annotationRun += 1;
    this.window?.removeAllListeners("closed");
    this.window?.close();
    this.window = undefined;
    this.attachedTo?.contentView.removeChildView(this.view);
    this.attachedTo = undefined;
    if (!this.contents.isDestroyed()) this.contents.close({ waitForBeforeUnload: false });
  }
}

/**
 * Browser panel tabs as native views over the window. Each page keeps running while its tab is
 * hidden or another project is shown. Pages get no preload and no bridge to the app.
 */
export class BrowserService {
  private readonly tabs = new Map<string, BrowserTab>();
  private configured = new WeakSet<Session>();

  constructor(readonly host: BrowserHost) {}

  emit(event: BrowserEvent): void { this.host.emit(event); }

  owns(tab: BrowserTab): boolean { return this.tabs.get(tab.id) === tab; }

  /** Pages may copy to the clipboard; every other permission is refused. */
  private configure(profile: Session): Session {
    if (this.configured.has(profile)) return profile;
    this.configured.add(profile);
    profile.setPermissionRequestHandler((_contents, permission, callback) => callback(permission === "clipboard-sanitized-write"));
    profile.setPermissionCheckHandler((_contents, permission) => permission === "clipboard-sanitized-write");
    return profile;
  }

  /** A pop-up shares its opener's profile and becomes a new panel tab. */
  adopt(projectID: string, profile: Session, isPrivate: boolean, existing?: WebContents): BrowserTab {
    const id = newID();
    const tab = new BrowserTab(id, projectID, profile, isPrivate, this, existing);
    this.tabs.set(id, tab);
    const window = this.host.window();
    if (window) tab.attach(window);
    this.host.openTab(projectID, id, isPrivate);
    return tab;
  }

  private tab(id: string): BrowserTab {
    const tab = this.tabs.get(id);
    if (!tab) throw new Error("This browser tab has closed.");
    return tab;
  }

  /** Created on first display. A restored tab shows its saved address and loads when first shown. */
  create(id: string, projectID: string): BrowserState {
    const existing = this.tabs.get(id);
    if (existing) return { ...existing.state };
    const saved = this.host.tab(projectID, id);
    if (!saved) throw new Error("This browser tab has closed.");
    const profile = this.configure(saved.isPrivate ? session.fromPartition(`octo-private-${id}`, { cache: false }) : session.fromPartition(DEFAULT_PARTITION));
    const tab = new BrowserTab(id, projectID, profile, saved.isPrivate, this);
    this.tabs.set(id, tab);
    const window = this.host.window();
    if (window) tab.attach(window);
    if (saved.address) tab.restore(saved.address);
    else this.emit({ type: "focusAddress", id });
    return { ...tab.state };
  }

  close(id: string): void {
    const tab = this.tabs.get(id);
    if (!tab) return;
    this.tabs.delete(id);
    tab.close();
    // A private profile ends with the last tab that uses it; its pop-ups share it.
    if (tab.state.isPrivate && ![...this.tabs.values()].some((t) => t.profile === tab.profile)) void tab.profile.clearStorageData().catch(() => undefined);
    this.emit({ type: "closed", id });
  }

  setBounds(id: string, bounds: BrowserBounds, fitScale = 1): void { this.tabs.get(id)?.setBounds(bounds, fitScale); }
  setVisible(id: string, visible: boolean): void { this.tabs.get(id)?.setVisible(visible); }
  /** Native views draw above the app's own content, so overlays hide every page while they're open. */
  hideAll(): void { for (const tab of this.tabs.values()) tab.setVisible(false); }
  focus(id: string): void { this.tabs.get(id)?.focus(); }
  navigate(id: string, address: string): void { this.tab(id).open(address); }
  back(id: string): void { this.tab(id).back(); }
  forward(id: string): void { this.tab(id).forward(); }
  reload(id: string): void { this.tab(id).reload(); }
  hardReload(id: string): void { this.tab(id).hardReload(); }
  stop(id: string): void { this.tab(id).stop(); }
  openExternally(id: string): void { this.tab(id).openExternally(); }
  openDevTools(id: string): void { this.tab(id).openDevTools(); }
  annotate(id: string): Promise<void> { return this.tab(id).annotate(); }
  setZoom(id: string, direction: "in" | "out" | "reset"): void { this.tab(id).setZoom(direction); }
  setDevice(id: string, device: BrowserDevice | undefined, landscape = false): void { this.tab(id).setDevice(device, landscape); }
  setAppearance(id: string, appearance: BrowserAppearance): Promise<void> { return this.tab(id).setAppearance(appearance); }
  openSeparateWindow(id: string): void { this.tab(id).openInWindow(); }
  returnToPanel(id: string): void { this.tab(id).returnFromWindow(); }
  confirmExternal(id: string, open: boolean): void { this.tab(id).confirmExternal(open); }

  async screenshot(id: string): Promise<void> {
    const tab = this.tab(id);
    if (!tab.state.url) return;
    const data = await tab.capture();
    if (data) this.host.attachScreenshot(data, tab.projectID);
  }

  /** Clears cookies for this tab's profile: the shared default one, or this private tab and its pop-ups. */
  async clearCookies(id: string): Promise<void> { await this.tab(id).profile.clearStorageData({ storages: ["cookies"] }); }
  async clearCache(id: string): Promise<void> {
    const profile = this.tab(id).profile;
    await profile.clearCache();
    await profile.clearCodeCaches({});
    await profile.clearStorageData({ storages: ["cachestorage"] });
  }

  /** A theme or window change can need every page re-attached to the current window. */
  attachAll(window: BrowserWindow): void { for (const tab of this.tabs.values()) tab.attach(window); }

  shutdown(): void { for (const id of [...this.tabs.keys()]) this.close(id); }
}
