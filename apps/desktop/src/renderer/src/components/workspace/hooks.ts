import { useEffect, useRef, useState } from "react";
import { MENU_GROUPS } from "../../../../shared/menu";
import { appState, checkoutRoot, isProjectChat, selectedProject, useApp, useMirror } from "../../state/app";
import { useUI } from "../../state/ui";
import { useTerminal } from "../../state/terminal";
import { useReview } from "../../state/review";
import { refreshCheckout } from "../../state/git";
import { checkFiles, useFiles } from "../../state/files";
import { commandForKey, commands, isAvailable, menuCommands } from "../../lib/commands";
import { applyTheme, resolveTheme } from "../../theme/theme";
import { call, on, run } from "../../bridge";

export function useWindowWidth(): number {
  const [width, setWidth] = useState(window.innerWidth);
  useEffect(() => {
    const resize = () => setWidth(window.innerWidth);
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, []);
  return width;
}

const terminalShowing = () => useUI.getState().showingTerminal && isProjectChat(appState());
/** Something modal has the keyboard: a dialog, the palette or a popover. */
const keyboardTaken = () => !!document.querySelector("dialog[open]") || useUI.getState().overlays.length > 0;

/**
 * App shortcuts win over the terminal and editors, on key-down and on the matching key-up.
 * Unavailable app commands are reserved too, so they never leak to a shell. Holding ⌘ alone for 0.65 s reveals the held-shortcut badges.
 */
export function useKeyRouter(): void {
  useEffect(() => {
    let reveal: ReturnType<typeof setTimeout> | undefined;
    const consumed = new Set<string>();
    const hideHints = () => {
      clearTimeout(reveal); reveal = undefined;
      if (useUI.getState().shortcutHints) useUI.setState({ shortcutHints: false });
    };
    const keyDown = (event: KeyboardEvent) => {
      if (event.isComposing || event.keyCode === 229) return;
      if (event.key === "Meta") {
        if (!reveal && !event.repeat && !keyboardTaken() && document.hasFocus()) {
          reveal = setTimeout(() => { if (!keyboardTaken()) useUI.setState({ shortcutHints: true }); }, 650);
        }
        return;
      }
      hideHints();
      if (keyboardTaken()) return;
      const inTerminal = terminalShowing();
      const command = commandForKey(event, commands(), inTerminal);
      if (!command) return;
      // Pierre's editor keeps its own find and replace.
      if (command.id === "find" && event.composedPath().some((node) => node instanceof HTMLElement && node.dataset.testid === "file-editor")) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      consumed.add(event.code);
      if (isAvailable(command, inTerminal) && !(event.repeat && command.id === "send")) command.action();
    };
    const keyUp = (event: KeyboardEvent) => {
      if (event.key === "Meta" || !event.metaKey) hideHints();
      if (consumed.delete(event.code)) { event.preventDefault(); event.stopImmediatePropagation(); }
    };
    const focusChanged = () => {
      hideHints();
      // Indicators pause in an inactive window, as Core Animation's do.
      document.documentElement.dataset.inactive = String(!document.hasFocus());
    };
    window.addEventListener("keydown", keyDown, true);
    window.addEventListener("keyup", keyUp, true);
    window.addEventListener("blur", focusChanged);
    window.addEventListener("focus", focusChanged);
    return () => {
      hideHints();
      window.removeEventListener("keydown", keyDown, true);
      window.removeEventListener("keyup", keyUp, true);
      window.removeEventListener("blur", focusChanged);
      window.removeEventListener("focus", focusChanged);
    };
  }, []);
}

/** Mirrors the commands into the menu bar, coalescing bursts such as streamed text into one update. */
export function useMenuSync(): void {
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined, sent = "";
    const publish = () => {
      timer = undefined;
      const shown = menuCommands(commands(), terminalShowing())
        .filter((c) => (MENU_GROUPS as readonly string[]).includes(c.group) || ["newThread", "newChat", "addProject", "settings"].includes(c.id));
      const text = JSON.stringify(shown);
      if (text !== sent) { sent = text; run("app", "setMenu", shown); }
    };
    const schedule = () => { if (!timer) timer = setTimeout(publish, 120); };
    const unsubscribe = [useMirror, useUI, useTerminal, useReview, useFiles].map((store) => store.subscribe(schedule));
    publish();
    // Menu items, native browser pages and main's own navigation (Open in Neovim) arrive here.
    const off = on("ui:event", (event) => {
      switch (event.type) {
        case "showTerminal": useUI.getState().showTerminal(true); return;
        case "focusComposer": case "showThread": useUI.getState().focusComposer(); return;
        case "command": {
          if (keyboardTaken()) return;
          const command = commands().find((c) => c.id === event.id);
          if (command && isAvailable(command, terminalShowing())) command.action();
        }
      }
    });
    return () => { clearTimeout(timer); unsubscribe.forEach((u) => u()); off(); };
  }, []);
}

/**
 * Keeps the selected checkout's Changes and Git state current: on selection, when its Git directory
 * changes outside Octo, when the window regains focus and when an agent turn ends.
 */
export function useCheckoutRefresh(): void {
  const target = useApp((s) => isProjectChat(s) ? { projectID: selectedProject(s)!.id, root: checkoutRoot(s)! } : undefined);
  const running = useApp((s) => s.running.length);
  const projectID = target?.projectID, root = target?.root;
  useEffect(() => {
    if (!projectID || !root) return;
    const refresh = () => void refreshCheckout(projectID, root);
    refresh();
    run("review", "watch", root);
    const off = on("review:event", (event) => { if (event.root === root) refresh(); });
    const focus = () => { refresh(); void checkFiles(); };
    window.addEventListener("focus", focus);
    return () => { off(); window.removeEventListener("focus", focus); };
  }, [projectID, root]);
  const previous = useRef(running);
  useEffect(() => {
    // A finished turn may have edited files or committed.
    if (running < previous.current && projectID && root) void refreshCheckout(projectID, root);
    previous.current = running;
  }, [running, projectID, root]);
}

/** Applies the chosen theme, resolving System against the Mac's appearance and accent. */
export function useThemeApplication(): void {
  const theme = useApp((s) => s.theme), dark = useApp((s) => s.systemDark);
  useEffect(() => {
    let active = true;
    void call("app", "systemTheme").then((system) => {
      if (!active) return;
      applyTheme(resolveTheme(theme, { dark, accent: system.accent }));
      document.documentElement.dataset.reduceTransparency = String(system.reduceTransparency);
    }).catch((error) => useUI.getState().showError(String(error)));
    return () => { active = false; };
  }, [theme, dark]);
}
