import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { AppWindow, Camera, ChevronLeft, ChevronRight, Compass, Ellipsis, EyeOff, Globe, MousePointerClick, RotateCw, RotateCwSquare, X } from "lucide-react";
import { BROWSER_DEVICES, ZOOM_LEVELS, browserViewport, fitScale, type BrowserAppearance, type BrowserDevice } from "../../../../shared/browser";
import { openBrowserPage, useBrowsers } from "../../state/browser";
import { useUI } from "../../state/ui";
import { popup, separator } from "../../lib/menu";
import { call, run } from "../../bridge";
import { BorderedButton, CapsulePicker, cx, EmptyState, HoverButton } from "../controls";
import styles from "./review.module.css";

/**
 * One browser tab. The page is a native view main keeps alive while the tab is hidden; this pane
 * positions it over its viewport and hides it behind dialogs, which it would otherwise cover.
 */
export function BrowserPane({ id, projectID, visible }: { id: string; projectID: string; visible: boolean }) {
  const page = useBrowsers((s) => s.pages[id]);
  const focusAddress = useBrowsers((s) => s.focusAddress[id]);
  const [address, setAddress] = useState("");
  const viewport = useRef<HTMLDivElement>(null), field = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void openBrowserPage(id, projectID).catch((error) => useUI.getState().showError(String(error instanceof Error ? error.message : error)));
    return () => run("browser", "setVisible", id, false);
  }, [id, projectID]);
  const pageAddress = page?.address;
  useEffect(() => { if (pageAddress !== undefined) setAddress(pageAddress); }, [pageAddress]);
  useEffect(() => { if (focusAddress && visible) { field.current?.focus(); field.current?.select(); } }, [focusAddress, visible]);
  // A new tab with nothing to restore starts in its address field.
  const blank = !!page && !page.url && !page.restoring;
  useEffect(() => { if (visible && blank) field.current?.focus(); }, [visible, blank]);

  // A link to another app waits for an explicit choice.
  const pending = page?.pendingExternal;
  useEffect(() => {
    if (!pending) return;
    void call("app", "confirm", {
      message: `Open in ${pending.application}?`, detail: `This page wants to open a link outside Octo:\n${pending.url.slice(0, 200)}`, buttons: ["Cancel", "Open"],
    }).then((choice) => run("browser", "confirmExternal", id, choice === 1));
  }, [pending, id]);

  const showsPage = !!page && !!page.url && !page.detached && !pending;
  const ready = !!page, device = page?.device, landscape = page?.landscape ?? false;
  useLayoutEffect(() => {
    const box = viewport.current;
    if (!box || !ready) return;
    const place = () => {
      const r = box.getBoundingClientRect();
      const emulated = browserViewport(device, landscape);
      // An emulated device is fitted inside a 12 px margin and centred.
      const scale = emulated ? fitScale(emulated, { width: r.width - 24, height: r.height - 24 }) : 1;
      const width = emulated ? emulated.width * scale : r.width, height = emulated ? emulated.height * scale : r.height;
      run("browser", "setBounds", id, { x: r.x + (r.width - width) / 2, y: r.y + (r.height - height) / 2, width, height }, scale);
      run("browser", "setVisible", id, visible && showsPage);
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(box);
    window.addEventListener("resize", place);
    return () => { observer.disconnect(); window.removeEventListener("resize", place); };
  }, [id, visible, showsPage, ready, device, landscape]);

  if (!page) return null;
  const hasPage = !!page.url;
  const emulated = browserViewport(page.device, page.landscape);
  const clearCookies = async () => {
    const choice = await call("app", "confirm", {
      message: "Clear cookies?", buttons: ["Cancel", "Clear Cookies"], destructive: 1,
      detail: page.isPrivate ? "This signs you out of sites in this private tab and the pop-ups it opened." : "This signs you out of sites in every non-private browser tab in Octo. Private tabs are unaffected.",
    });
    if (choice === 1) run("browser", "clearCookies", id);
  };
  const moreMenu = (anchor: Element) => void popup([
    { label: "Hard Reload", enabled: hasPage, action: () => run("browser", "hardReload", id) },
    { label: "Open Web Inspector", enabled: hasPage, action: () => run("browser", "openDevTools", id) },
    page.detached ? { label: "Return Page to Panel", action: () => run("browser", "returnToPanel", id) }
      : { label: "Open in Separate Window", enabled: hasPage, action: () => run("browser", "openSeparateWindow", id) },
    { label: page.device ? "Hide Device Toolbar" : "Show Device Toolbar", action: () => run("browser", "setDevice", id, page.device ? undefined : "phone", false) },
    { type: "submenu", label: "Appearance", items: (["system", "light", "dark"] as BrowserAppearance[]).map((appearance) => ({
      label: appearance === "system" ? "System" : appearance === "light" ? "Light" : "Dark", checked: page.appearance === appearance,
      action: () => run("browser", "setAppearance", id, appearance) })) },
    separator,
    { type: "header", label: `Zoom: ${Math.round(page.zoom * 100)}%` },
    { label: "Zoom In", enabled: page.zoom < ZOOM_LEVELS.at(-1)!, action: () => run("browser", "setZoom", id, "in") },
    { label: "Zoom Out", enabled: page.zoom > ZOOM_LEVELS[0], action: () => run("browser", "setZoom", id, "out") },
    { label: "Actual Size", enabled: page.zoom !== 1, action: () => run("browser", "setZoom", id, "reset") },
    separator,
    { type: "header", label: page.isPrivate ? "Profile: Private" : "Profile: Default" },
    { label: "Clear Cookies…", action: () => void clearCookies() },
    { label: "Clear Cache", action: () => run("browser", "clearCache", id) },
  ], anchor);

  return (
    <div className={styles.browser}>
      <div className={styles.browserToolbar}>
        <HoverButton aria-label="Back" help="Back" disabled={!page.canGoBack} onClick={() => run("browser", "back", id)}><ChevronLeft size={15} /></HoverButton>
        <HoverButton aria-label="Forward" help="Forward" disabled={!page.canGoForward} onClick={() => run("browser", "forward", id)}><ChevronRight size={15} /></HoverButton>
        <HoverButton aria-label={page.loading ? "Stop loading" : "Reload"} help={page.loading ? "Stop" : "Reload"} disabled={!hasPage}
          onClick={() => run("browser", page.loading ? "stop" : "reload", id)}>{page.loading ? <X size={14} /> : <RotateCw size={14} />}</HoverButton>
        <form className={styles.address} onSubmit={(e) => { e.preventDefault(); run("browser", "navigate", id, address); field.current?.blur(); }}>
          {page.isPrivate && <span title="Private tab: cookies and website data are discarded when the tab closes" aria-label="Private tab"><EyeOff size={12} /></span>}
          <input ref={field} data-plain aria-label="Address" placeholder={page.isPrivate ? "Search or enter address privately" : "Search or enter address"}
            value={address} onChange={(e) => setAddress(e.target.value)} />
        </form>
        <HoverButton aria-label={page.annotating ? "Stop annotating" : "Annotate elements and regions"} selected={page.annotating} disabled={!hasPage}
          help="Annotate elements and regions: click an element or drag a region to attach it to the draft" onClick={() => run("browser", "annotate", id)}><MousePointerClick size={14} /></HoverButton>
        <HoverButton aria-label="Attach page screenshot" help="Attach a screenshot of the visible page to the draft" disabled={!hasPage} onClick={() => run("browser", "screenshot", id)}><Camera size={14} /></HoverButton>
        <HoverButton aria-label="Open in default browser" help="Open in default browser" disabled={!hasPage} onClick={() => run("browser", "openExternally", id)}><Compass size={14} /></HoverButton>
        <HoverButton aria-label="More browser actions" help="More browser actions" onClick={(e) => moreMenu(e.currentTarget)}><Ellipsis size={15} /></HoverButton>
      </div>
      <div className={styles.loadingBar} style={{ opacity: page.loading ? 1 : 0 }} />
      {page.device && (
        <div className={styles.deviceToolbar}>
          <CapsulePicker label="Device" value={page.device} options={(Object.keys(BROWSER_DEVICES) as BrowserDevice[]).map((device) => ({ value: device, title: BROWSER_DEVICES[device].title }))}
            onChange={(device) => run("browser", "setDevice", id, device, page.landscape)} />
          <HoverButton aria-label="Rotate viewport" help="Rotate" onClick={() => run("browser", "setDevice", id, page.device, !page.landscape)}><RotateCwSquare size={14} /></HoverButton>
          {emulated && <span className={styles.viewportSize}>{emulated.width} × {emulated.height}</span>}
          <span className={styles.spacer} />
          <HoverButton aria-label="Hide device toolbar" help="Hide device toolbar" onClick={() => run("browser", "setDevice", id, undefined, false)}><X size={13} /></HoverButton>
        </div>
      )}
      <hr className={styles.hairline} />
      {page.annotating && <div className={styles.browserHint}>Click an element or drag a region · Esc to cancel</div>}
      {page.error && (
        <div className={styles.browserError} role="alert">
          <span>{page.error}</span>
          <HoverButton onClick={() => run("browser", "hardReload", id)}>Reload</HoverButton>
        </div>
      )}
      <div ref={viewport} className={cx(styles.viewport, emulated && styles.emulated)} data-testid={`browser-viewport-${id}`}>
        {page.detached ? (
          <EmptyState icon={<AppWindow size={30} strokeWidth={1.4} />} title="Open in a separate window" description={page.title || "This page is showing in its own window."}>
            <BorderedButton onClick={() => run("browser", "returnToPanel", id)}>Return to Panel</BorderedButton>
          </EmptyState>
        ) : !hasPage && (
          <EmptyState icon={page.isPrivate ? <EyeOff size={30} strokeWidth={1.4} /> : <Globe size={30} strokeWidth={1.4} />} title={page.isPrivate ? "Private Browser" : "Browser"}
            description={page.isPrivate ? "Cookies, storage and history in this tab are discarded when it closes."
              : "Open your dev server or any page. Annotate elements and regions to attach them to the draft with a screenshot."}>
            <BorderedButton onClick={() => run("browser", "navigate", id, "localhost:3000")}>Open localhost:3000</BorderedButton>
          </EmptyState>
        )}
      </div>
    </div>
  );
}
