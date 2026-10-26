import { app, BrowserWindow, clipboard, dialog, Menu, nativeImage, nativeTheme, shell, systemPreferences, type MenuItemConstructorOptions } from "electron";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { UsageLedger, type UsageRecord } from "@octo/agents";
import { fileScheme, isTerminalTarget, OPEN_TARGETS, preferredTarget, type AvailableTarget } from "../../shared/openTargets";
import type { StateSnapshot } from "../../shared/state";
import type { AppStore } from "../store/appStore";
import type { AppInfo } from "../../shared/app";
import type { MenuCommand, PopupItem } from "../../shared/menu";

function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: 15_000 }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
}

/** App-level actions: identity, the state snapshot, Launch Services, the clipboard and usage logs. */
export class AppService {
  private applicationPaths = new Map<string, string | undefined>();
  private applicationIcons = new Map<string, string | undefined>();
  private readonly ledger = new UsageLedger();

  constructor(private readonly store: AppStore, private readonly identity: { channel: "release" | "dev"; dataDirectory: string },
              private readonly hooks: {
                openCheckoutInEditor(projectID: string, directory: string): void;
                openFileInEditor(projectID: string, directory: string, path: string, line: number): Promise<void>;
                setMenu(commands: MenuCommand[]): void;
              }) {}

  /** The renderer's current commands, mirrored into the menu bar. */
  setMenu(commands: MenuCommand[]): void {
    this.hooks.setMenu(commands);
  }

  /**
   * A native menu at a point in the window, or at the pointer. Resolves with the chosen item's id,
   * or undefined when dismissed. Native menus draw above browser pages.
   */
  popupMenu(items: PopupItem[], position?: { x: number; y: number }): Promise<string | undefined> {
    return new Promise((resolve) => {
      let chosen: string | undefined;
      const icon = (item: { icon?: string; symbol?: string }) => {
        const image = item.icon ? nativeImage.createFromDataURL(item.icon) : undefined;
        // Icons arrive at 32 px and draw at 16 pt, so Retina menus show every pixel.
        if (image && !image.isEmpty()) return nativeImage.createFromBuffer(image.toPNG(), { scaleFactor: Math.max(1, image.getSize().width / 16) });
        const symbol = item.symbol && process.platform === "darwin" ? nativeImage.createMenuSymbol(item.symbol) : undefined;
        return symbol && !symbol.isEmpty() ? symbol : undefined;
      };
      const build = (list: PopupItem[]): MenuItemConstructorOptions[] => list.map((item): MenuItemConstructorOptions => {
        switch (item.type) {
          case "separator": return { type: "separator" };
          case "header": return { type: "header", label: item.label };
          case "submenu": return { label: item.label, enabled: item.enabled ?? true, icon: icon(item), submenu: build(item.items) };
          default: return {
            label: item.label, enabled: item.enabled ?? true, toolTip: item.toolTip, icon: icon(item),
            ...(item.checked !== undefined ? { type: "checkbox" as const, checked: item.checked } : {}),
            ...(item.accelerator ? { accelerator: item.accelerator, registerAccelerator: false } : {}),
            click: () => { chosen = item.id; },
          };
        }
      });
      const window = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0];
      const menu = Menu.buildFromTemplate(build(items));
      // The click handler runs before the close callback.
      menu.popup({ window, ...(position ? { x: Math.round(position.x), y: Math.round(position.y) } : {}), callback: () => setTimeout(() => resolve(chosen), 0) });
    });
  }

  /**
   * A native confirmation sheet. Returns the chosen button's index; Cancel is always the first
   * button and Escape picks it.
   */
  async confirm(options: { message: string; detail?: string; buttons: string[]; destructive?: number }): Promise<number> {
    const owner = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0];
    const settings: Electron.MessageBoxOptions = {
      type: "warning", message: options.message, detail: options.detail, buttons: options.buttons, cancelId: 0, defaultId: options.destructive !== undefined ? 0 : options.buttons.length - 1,
      noLink: true,
    };
    const result = owner ? await dialog.showMessageBox(owner, settings) : await dialog.showMessageBox(settings);
    return result.response;
  }

  info(): AppInfo {
    return { productName: app.getName(), version: app.getVersion(), channel: this.identity.channel, platform: process.platform, dataDirectory: this.identity.dataDirectory };
  }

  snapshot(): StateSnapshot {
    return this.store.state.snapshot();
  }

  /** The System theme follows the OS appearance and, on macOS, its accent colour. */
  systemTheme(): { dark: boolean; accent?: string; reduceTransparency: boolean } {
    let accent: string | undefined;
    try { accent = process.platform === "darwin" || process.platform === "win32" ? systemPreferences.getAccentColor().slice(0, 6) : undefined; } catch { accent = undefined; }
    return { dark: nativeTheme.shouldUseDarkColors, accent, reduceTransparency: nativeTheme.prefersReducedTransparency };
  }

  async openExternal(url: string): Promise<void> {
    if (!/^(https?|mailto):/i.test(url)) throw new Error("Only web and mail links open in another app.");
    await shell.openExternal(url);
  }

  revealInFinder(path: string): void {
    shell.showItemInFolder(path);
  }

  async readText(): Promise<string> { return clipboard.readText(); }

  async copyText(text: string): Promise<void> {
    await clipboard.writeText(text);
  }

  private async applicationPath(bundleID: string): Promise<string | undefined> {
    if (this.applicationPaths.has(bundleID)) return this.applicationPaths.get(bundleID);
    let path: string | undefined;
    try {
      // A Spotlight query string, not a shell command.
      const found = (await run("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == "${bundleID.replace(/"/g, "")}"`])).split("\n").filter((p) => p.endsWith(".app"));
      path = found.find((p) => p.startsWith("/Applications/") || p.startsWith(join(homedir(), "Applications"))) ?? found[0];
    } catch { path = undefined; }
    this.applicationPaths.set(bundleID, path);
    return path;
  }

  /**
   * An app's own icon as a 32 px data URL. `app.getFileIcon` gives every bundle the generic
   * document icon on macOS; Quick Look's thumbnail of an app is the icon Finder shows.
   */
  private async applicationIcon(path: string): Promise<string | undefined> {
    if (this.applicationIcons.has(path)) return this.applicationIcons.get(path);
    let icon: string | undefined;
    try {
      const image = await nativeImage.createThumbnailFromPath(path, { width: 32, height: 32 });
      icon = image.isEmpty() ? undefined : image.toDataURL();
    } catch { icon = undefined; }
    this.applicationIcons.set(path, icon);
    return icon;
  }

  /** Neovim and Finder are always listed; apps only when Launch Services knows them. */
  async openTargets(): Promise<AvailableTarget[]> {
    this.applicationPaths.clear();
    const result: AvailableTarget[] = [];
    for (const target of OPEN_TARGETS) {
      if (target.kind === "app") {
        const path = await this.applicationPath(target.bundleID!);
        if (!path) continue;
        result.push({ ...target, icon: await this.applicationIcon(path) });
      } else if (target.kind === "finder") {
        result.push({ ...target, icon: await this.applicationIcon("/System/Library/CoreServices/Finder.app") });
      } else {
        result.push({ ...target });
      }
    }
    return result;
  }

  /**
   * Opens a checkout, or a file at a line where the target supports it. Terminals get the checkout.
   * Returns false when the target app is no longer installed.
   */
  async openTarget(id: string, location: { projectID: string; checkout: string; path?: string; line?: number }): Promise<boolean> {
    const target = preferredTarget(id);
    const file = location.path ? join(location.checkout, location.path) : undefined;
    if (target.kind === "neovim") {
      if (file && location.path) await this.hooks.openFileInEditor(location.projectID, location.checkout, location.path, location.line ?? 1);
      else this.hooks.openCheckoutInEditor(location.projectID, location.checkout);
      return true;
    }
    if (target.kind === "finder") {
      if (file) shell.showItemInFolder(file); else void shell.openPath(location.checkout);
      return true;
    }
    const application = await this.applicationPath(target.bundleID!);
    if (!application || !existsSync(application)) {
      this.applicationPaths.delete(target.bundleID!);
      this.store.state.update((d) => { d.error = `${target.title} is no longer installed.`; });
      return false;
    }
    let argument = file && !isTerminalTarget(target) ? file : location.checkout;
    const scheme = fileScheme(target);
    if (file && scheme) argument = `${scheme}://file${encodeURI(file)}:${Math.max(1, location.line ?? 1)}`;
    try {
      await run("/usr/bin/open", ["-a", application, "--", argument]);
    } catch (error) {
      if (file && scheme) {
        // This installation does not register the line scheme; open the plain file.
        await run("/usr/bin/open", ["-a", application, "--", file]).catch((e) => this.store.state.update((d) => { d.error = `Could not open in ${target.title}: ${(e as Error).message}`; }));
      } else {
        this.store.state.update((d) => { d.error = `Could not open in ${target.title}: ${(error as Error).message}`; });
      }
    }
    return true;
  }

  usageRecords(since: number): Promise<UsageRecord[]> {
    return this.ledger.records(since);
  }
}
