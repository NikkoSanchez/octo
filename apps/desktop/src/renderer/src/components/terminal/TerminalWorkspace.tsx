import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Columns2, Ellipsis, Maximize2, Plus, Rows2, X } from "lucide-react";
import { markdownFileLink, splitDividers, splitFrames, type Rect } from "@octo/core";
import type { TerminalTabState } from "../../../../shared/terminal";
import { appState, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { bindSurface, closeTerminal, startTerminals, useTerminal } from "../../state/terminal";
import { terminalTheme, bindingMatches } from "../../terminal/config";
import { GhosttyTerminalSurface } from "../../terminal/ghostty/surface";
import { contextMenu, popup, separator } from "../../lib/menu";
import { call, isMac, run } from "../../bridge";
import { cx, HoverButton } from "../controls";
import { Sheet } from "../overlays/Sheet";
import styles from "./terminal.module.css";

const DIVIDER = 5;

/**
 * The project's terminal workspace: a tab strip over tiled split panes. Every tab and pane of every
 * project stays mounted; hidden surfaces keep ingesting output and only stop drawing.
 */
export default function TerminalWorkspace({ visible, projectID }: { visible: boolean; projectID?: string }) {
  const workspace = useTerminal((s) => s.workspace);
  useEffect(() => startTerminals(), []);
  useEffect(() => { if (visible && projectID) run("terminal", "ensureTab", projectID); }, [visible, projectID]);
  const tabs = workspace.tabs.filter((t) => t.projectID === projectID);
  const selectedID = projectID ? workspace.selected[projectID] : undefined;
  const selected = tabs.find((t) => t.id === selectedID);

  return <>
    <div className={styles.workspace} inert={!visible} aria-hidden={!visible} style={{ transform: visible ? "none" : "translateY(110vh)" }}>
      <div className={styles.tabBar} role="tablist" aria-label="Terminal tabs">
        {tabs.map((tab) => <TabTitle key={tab.id} tab={tab} selected={tab.id === selectedID} />)}
        <HoverButton aria-label="New terminal tab" help="New terminal tab (⌘T)" onClick={() => { if (projectID) run("terminal", "newTab", projectID); }}><Plus size={15} /></HoverButton>
        <span className={styles.spacer} />
        <HoverButton aria-label="Split terminal right" help="Split right (⌘D)" disabled={!selected || selected.exited} onClick={() => { if (selected) run("terminal", "split", selected.id, "right"); }}><Columns2 size={14} /></HoverButton>
        <HoverButton aria-label="Split terminal down" help="Split down (⇧⌘D)" disabled={!selected || selected.exited} onClick={() => { if (selected) run("terminal", "split", selected.id, "down"); }}><Rows2 size={14} /></HoverButton>
        <HoverButton aria-label="Zoom terminal pane" help="Zoom pane (⇧⌘↩)" selected={!!selected?.layout.zoomed} disabled={!selected || selected.panes.length < 2}
          onClick={() => { if (selected) run("terminal", "toggleZoom", selected.id); }}><Maximize2 size={14} /></HoverButton>
        <HoverButton aria-label="Terminal options" help="More terminal actions" disabled={!selected}
          onClick={(e) => { if (selected) void popup([
            { label: "Rename Tab…", action: () => useUI.setState({ renamingTerminal: selected.id }) },
            { label: "Equalize Panes", enabled: selected.panes.length > 1, action: () => run("terminal", "equalize", selected.id) },
            separator,
            { label: "Close Pane", enabled: selected.panes.length > 1, action: () => void closeTerminal(selected.id, true) },
            { label: "Close Tab…", action: () => void closeTerminal(selected.id) },
          ], e.currentTarget); }}><Ellipsis size={14} /></HoverButton>
      </div>
      <div className={styles.body}>
        {workspace.tabs.map((tab) => <Tab key={tab.id} tab={tab} visible={visible && tab.id === selectedID && tab.projectID === projectID} />)}
      </div>
    </div>
    {workspace.setup && <CLISignIn pane={workspace.setup.pane} exited={workspace.setup.exited} />}
  </>;
}

/** A tab title; double-click renames it. A zoomed pane shows a badge. */
function TabTitle({ tab, selected }: { tab: TerminalTabState; selected: boolean }) {
  const title = tab.customName ?? tab.label;
  const rename = () => { run("terminal", "select", tab.id); useUI.setState({ renamingTerminal: tab.id }); };
  return (
    <div className={cx(styles.tab, selected && styles.selected)} onContextMenu={contextMenu(() => [
      { label: "Rename Tab…", action: rename },
      separator,
      { label: "Split Right", action: () => { run("terminal", "select", tab.id); run("terminal", "split", tab.id, "right"); } },
      { label: "Split Down", action: () => { run("terminal", "select", tab.id); run("terminal", "split", tab.id, "down"); } },
      separator,
      { label: "Close Tab…", action: () => void closeTerminal(tab.id) },
    ])}>
      <button type="button" role="tab" aria-selected={selected} title="Double-click to rename" onClick={() => run("terminal", "select", tab.id)} onDoubleClick={rename}>
        <span>{title}</span>
        {tab.layout.zoomed && <Maximize2 size={10} strokeWidth={2.5} aria-label="Pane zoomed" />}
      </button>
      <HoverButton aria-label={`Close ${title}`} help="Close tab (⌘W)" onClick={() => void closeTerminal(tab.id)}><X size={12} /></HoverButton>
    </div>
  );
}

/** One tab's split layout: panes at their frames, with draggable dividers between them. */
function Tab({ tab, visible }: { tab: TerminalTabState; visible: boolean }) {
  const dividerColor = useTerminal((s) => s.config?.splitDivider);
  const box = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 800, height: 600 });
  useLayoutEffect(() => {
    const node = box.current;
    if (!node) return;
    const resize = () => setSize({ width: node.clientWidth, height: node.clientHeight });
    const observer = new ResizeObserver(resize);
    observer.observe(node);
    resize();
    return () => observer.disconnect();
  }, []);
  const bounds: Rect = { x: 0, y: 0, ...size };
  const frames = splitFrames(tab.layout, bounds, DIVIDER);
  const zoomed = tab.layout.zoomed;

  return (
    <div ref={box} className={styles.tabContent} inert={!visible} aria-hidden={!visible} style={{ visibility: visible ? undefined : "hidden" }}>
      {tab.panes.map((pane) => (
        <Pane key={pane} id={pane} tab={tab} bounds={zoomed === pane ? bounds : frames.get(pane)} visible={visible && (!zoomed || zoomed === pane)} focused={tab.focusedPane === pane} />
      ))}
      {!zoomed && splitDividers(tab.layout, bounds, DIVIDER).map((divider) => {
        const horizontal = divider.axis === "horizontal";
        const setRatio = (ratio: number) => run("terminal", "setRatio", tab.id, ratio, divider.path);
        return (
          <div key={divider.path.join("/")} className={styles.divider} role="separator" tabIndex={0} aria-label="Resize terminal split"
            aria-orientation={horizontal ? "vertical" : "horizontal"} aria-valuemin={10} aria-valuemax={90} aria-valuenow={Math.round(divider.ratio * 100)}
            style={{ left: divider.frame.x, top: divider.frame.y, width: divider.frame.width, height: divider.frame.height, background: dividerColor, cursor: horizontal ? "col-resize" : "row-resize" }}
            onKeyDown={(e) => {
              if (!["ArrowLeft", "ArrowUp", "ArrowRight", "ArrowDown"].includes(e.key)) return;
              e.preventDefault();
              setRatio(divider.ratio + (e.key === "ArrowLeft" || e.key === "ArrowUp" ? -0.05 : 0.05));
            }}
            onPointerDown={(e) => {
              const node = e.currentTarget, rect = box.current!.getBoundingClientRect();
              node.setPointerCapture(e.pointerId);
              const move = (event: PointerEvent) => setRatio(horizontal
                ? (event.clientX - rect.left - divider.container.x) / divider.container.width
                : (event.clientY - rect.top - divider.container.y) / divider.container.height);
              const finish = () => { node.removeEventListener("pointermove", move); node.removeEventListener("pointerup", finish); node.removeEventListener("pointercancel", finish); };
              node.addEventListener("pointermove", move);
              node.addEventListener("pointerup", finish);
              node.addEventListener("pointercancel", finish);
            }} />
        );
      })}
      {tab.exited && <div className={styles.exited}>Process exited · <HoverButton onClick={() => run("terminal", "newTab", tab.projectID)}>New terminal</HoverButton></div>}
    </div>
  );
}

/** Runs a key the user bound in their Ghostty config. Returns false for actions Octo doesn't support. */
function performBinding(action: string, tab: TerminalTabState, surface: GhosttyTerminalSurface | undefined, host: HTMLElement | null): boolean {
  const [verb, argument = ""] = action.split(":");
  switch (verb) {
    case "new_tab": run("terminal", "newTab", tab.projectID); return true;
    case "close_surface": void closeTerminal(tab.id, true); return true;
    case "new_split":
      if (!["right", "left", "down", "up"].includes(argument)) return false;
      run("terminal", "split", tab.id, argument as "right"); return true;
    case "goto_split":
      if (!["next", "previous", "left", "right", "up", "down"].includes(argument)) return false;
      run("terminal", "focusDirection", tab.id, argument as "next"); return true;
    case "resize_split": {
      const [direction, amount] = argument.split(",");
      const rect = host?.closest(`.${styles.tabContent}`)?.getBoundingClientRect();
      if (!rect || !["left", "right", "up", "down"].includes(direction)) return false;
      run("terminal", "resizePane", tab.id, direction as "right", Math.max(1, Number(amount) || 10), { x: 0, y: 0, width: rect.width, height: rect.height });
      return true;
    }
    case "goto_tab": {
      const candidate = useTerminal.getState().workspace.tabs.filter((t) => t.projectID === tab.projectID)[Number(argument) - 1];
      if (!candidate) return false;
      run("terminal", "select", candidate.id); return true;
    }
    case "next_tab": run("terminal", "cycle", tab.projectID, 1); return true;
    case "previous_tab": run("terminal", "cycle", tab.projectID, -1); return true;
    case "copy_to_clipboard": { const text = surface?.getSelection(); if (text) run("app", "copyText", text); return true; }
    case "paste_from_clipboard": void surface?.pasteFromClipboard(() => call("app", "readText"), () => true); return true;
    case "select_all": surface?.selectAll(); return true;
    case "equalize_splits": run("terminal", "equalize", tab.id); return true;
    case "toggle_split_zoom": run("terminal", "toggleZoom", tab.id); return true;
    default: return false;
  }
}

/** One Ghostty surface bound to one pane. Its theme and font follow the app and the Ghostty config. */
function Pane({ id, tab, visible, focused, bounds }: { id: string; tab?: TerminalTabState; visible: boolean; focused: boolean; bounds?: Rect }) {
  const host = useRef<HTMLDivElement>(null);
  const surface = useRef<GhosttyTerminalSurface | undefined>(undefined);
  const showing = useRef(visible), currentTab = useRef(tab);
  showing.current = visible;
  currentTab.current = tab;
  const [error, setError] = useState<string>();
  const config = useTerminal((s) => s.config);
  const theme = useApp((s) => s.theme), dark = useApp((s) => s.systemDark);

  useEffect(() => {
    let alive = true, unbind: (() => void) | undefined;
    const paste = () => void surface.current?.pasteFromClipboard(() => call("app", "readText"), () => showing.current);
    void GhosttyTerminalSurface.create(host.current!, {
      theme: terminalTheme(theme, dark, config), font: { family: config?.fontFamily, size: config?.fontSize }, visible: showing.current,
      onData: (data) => run("terminal", "write", id, data),
      onResize: (cols, rows) => run("terminal", "resize", id, cols, rows),
      onSelectionChange: () => {},
      beforeKey: (event) => {
        if (event.defaultPrevented || !showing.current) return false;
        if ((isMac ? event.metaKey : event.ctrlKey) && !event.altKey && event.code === "KeyV") { event.preventDefault(); paste(); return false; }
        const current = currentTab.current;
        if (!current) return true;
        // Later bindings in the Ghostty config win, as in Ghostty.
        for (const [trigger, action] of [...(useTerminal.getState().config?.keybinds ?? [])].reverse()) {
          if (bindingMatches(event, trigger) && performBinding(action, current, surface.current, host.current)) { event.preventDefault(); return false; }
        }
        return true;
      },
      canActivateLink: (text) => /^https?:/i.test(text) || (!!currentTab.current && !!markdownFileLink(text, currentTab.current.directory)),
      onLinkActivate: (text, event) => {
        event.preventDefault();
        const current = currentTab.current;
        if (/^https?:/i.test(text)) { run("app", "openExternal", text); return; }
        const file = current && markdownFileLink(text, current.directory);
        if (current && file) run("app", "openTarget", appState().openTarget, { projectID: current.projectID, checkout: current.directory, path: file.path, line: file.line });
      },
      onContextMenu: (event) => {
        event.preventDefault();
        void popup([
          { label: "Copy", enabled: surface.current?.hasSelection() ?? false, action: () => { const text = surface.current?.getSelection(); if (text) run("app", "copyText", text); } },
          { label: "Paste", action: paste },
          { label: "Select All", action: () => surface.current?.selectAll() },
        ]);
      },
    }).then((created) => {
      if (!alive) { created.dispose(); return; }
      surface.current = created;
      unbind = bindSurface(id, created);
      const latest = useTerminal.getState().config;
      created.setTheme(terminalTheme(appState().theme, appState().systemDark, latest));
      void created.setFont({ family: latest?.fontFamily, size: latest?.fontSize });
      created.setVisible(showing.current);
      if (showing.current && focused) created.focus();
    }).catch((failure) => { if (alive) setError(String(failure instanceof Error ? failure.message : failure)); });
    return () => { alive = false; unbind?.(); surface.current?.dispose(); surface.current = undefined; };
    // The surface lives as long as its pane; theme and visibility changes apply below.
  }, [id]);

  // Hidden surfaces keep ingesting output and only stop drawing.
  useLayoutEffect(() => { surface.current?.setVisible(visible); if (visible && focused) surface.current?.focus(); }, [visible, focused]);
  useEffect(() => {
    surface.current?.setTheme(terminalTheme(theme, dark, config));
    void surface.current?.setFont({ family: config?.fontFamily, size: config?.fontSize });
  }, [theme, dark, config]);

  return (
    <div className={styles.pane} data-pane={id} inert={!visible} aria-hidden={!visible}
      style={{
        left: bounds?.x ?? 0, top: bounds?.y ?? 0, width: bounds?.width ?? "100%", height: bounds?.height ?? "100%",
        visibility: visible ? undefined : "hidden",
        opacity: focused || !visible || !tab || tab.panes.length < 2 ? 1 : config?.unfocusedSplitOpacity ?? 0.7, background: config?.unfocusedSplitFill,
      }}
      onFocusCapture={() => { if (tab && !focused) run("terminal", "focusPane", tab.id, id); }}
      onPointerDownCapture={() => { if (tab && !focused) run("terminal", "focusPane", tab.id, id); }}>
      <div ref={host} className={styles.mount} />
      {error && <p role="alert" className={styles.error}>{error}</p>}
    </div>
  );
}

/** The installed Claude CLI's browser sign-in, in a dedicated terminal. Credentials never reach Octo. */
function CLISignIn({ pane, exited }: { pane: string; exited: boolean }) {
  const close = () => { run("terminal", "closeSetup"); run("store", "claudeSetupClosed"); };
  useEffect(() => { if (exited) run("store", "refreshClaudeAuth"); }, [exited]);
  return (
    <Sheet label="Sign in through Claude CLI" width={640} close={close}>
      <div className={styles.setup}>
        <h2>Sign in through Claude CLI</h2>
        <p>Follow the CLI instructions and finish sign-in in your browser. If it asks for a code, paste it in the terminal below.</p>
        <div className={styles.setupTerminal}><Pane id={pane} visible focused /></div>
        <div className={styles.setupFooter}>
          <small>{exited ? "CLI finished. Close to refresh sign-in status." : "Closing ends this sign-in process."}</small>
          <span className={styles.spacer} />
          <HoverButton onClick={close}>Close</HoverButton>
        </div>
      </div>
    </Sheet>
  );
}
