import { create } from "zustand";
import type { GhosttyConfig, TerminalEvent, TerminalWorkspaceState } from "../../../shared/terminal";
import type { GhosttyTerminalSurface } from "../terminal/ghostty/surface";
import { nextOutput } from "../terminal/output";
import { call, on, run } from "../bridge";
import { useUI } from "./ui";

/** Main's terminal workspace (tabs, split layouts, focus) and the user's Ghostty settings. */
export const useTerminal = create<{ workspace: TerminalWorkspaceState; config?: GhosttyConfig }>(() => ({
  workspace: { version: -1, tabs: [], selected: {} },
}));

/**
 * Output per pane, outside React state: it feeds the bound surface directly, or waits for a surface
 * to bind. `cursor` is the UTF-16 end of the stream already applied, so replayed overlap is dropped.
 */
interface PaneOutput { cursor: number; text: string; unacknowledged: number; surface?: GhosttyTerminalSurface }
const panes = new Map<string, PaneOutput>();
export const surfaces = new Map<string, GhosttyTerminalSurface>();

function output(pane: string): PaneOutput {
  let entry = panes.get(pane);
  if (!entry) { entry = { cursor: 0, text: "", unacknowledged: 0 }; panes.set(pane, entry); }
  return entry;
}

/** Binds a mounted surface to its pane, writing anything that arrived before it mounted. */
export function bindSurface(id: string, surface: GhosttyTerminalSurface): () => void {
  surfaces.set(id, surface);
  const entry = output(id);
  entry.surface = surface;
  if (entry.text) surface.write(entry.text);
  if (entry.unacknowledged) run("terminal", "ack", id, entry.unacknowledged);
  entry.text = ""; entry.unacknowledged = 0;
  return () => {
    if (surfaces.get(id) !== surface) return;
    surfaces.delete(id);
    entry.surface = undefined;
  };
}

/**
 * Subscribes before requesting a snapshot, queues events that arrive meanwhile, drops replay
 * overlap and resynchronizes on a gap. Acknowledgments follow ingestion, which is main's backpressure.
 */
export function startTerminals(): () => void {
  let alive = true, syncing = false;
  let pending: TerminalEvent[] = [];

  const apply = (event: TerminalEvent) => {
    switch (event.type) {
      case "workspace": {
        // Monotonic versions reject a stale layout snapshot.
        if (event.workspace.version < useTerminal.getState().workspace.version) return;
        useTerminal.setState({ workspace: event.workspace });
        const live = new Set([...event.workspace.tabs.flatMap((t) => t.panes), ...(event.workspace.setup ? [event.workspace.setup.pane] : [])]);
        for (const id of panes.keys()) if (!live.has(id)) panes.delete(id);
        return;
      }
      case "focus":
        surfaces.get(event.pane)?.focus();
        return;
      case "exit":
        return;
      case "output": {
        const entry = output(event.pane);
        const next = nextOutput(entry.cursor, event);
        if (!next) { pending.push(event); void sync(); return; }
        entry.cursor = next.cursor;
        if (!next.data) return;
        if (entry.surface) { entry.surface.write(next.data); run("terminal", "ack", event.pane, next.data.length); }
        else { entry.text += next.data; entry.unacknowledged += next.data.length; }
      }
    }
  };

  async function sync(): Promise<void> {
    if (!alive || syncing) return;
    syncing = true;
    try {
      const snapshot = await call("terminal", "snapshot");
      if (!alive) return;
      for (const [id, text] of Object.entries(snapshot.replay)) {
        const surface = surfaces.get(id);
        panes.set(id, { cursor: snapshot.cursors[id], text: surface ? "" : text, unacknowledged: 0, surface });
        surface?.resetAndWrite(text);
      }
      apply({ type: "workspace", workspace: snapshot.workspace });
      const queued = pending;
      pending = [];
      syncing = false;
      queued.forEach(apply);
    } catch (error) {
      if (alive) useUI.getState().showError(String(error instanceof Error ? error.message : error));
    } finally { syncing = false; }
  }

  const off = on("terminal:event", (event) => { if (syncing) pending.push(event); else apply(event); });
  void sync();
  void call("terminal", "ghosttyConfig").then((config) => { if (alive) useTerminal.setState({ config }); })
    .catch((error) => { if (alive) useUI.getState().showError(String(error instanceof Error ? error.message : error)); });
  return () => { alive = false; off(); };
}

/** Closes a tab (or the focused pane), asking first when a process would be stopped. */
export async function closeTerminal(id: string, pane = false): Promise<void> {
  const action = pane ? "closePane" : "closeTab";
  const result = await call("terminal", action, id);
  if (result.closed) return;
  const choice = await call("app", "confirm", { message: "Close terminal tab?", detail: result.confirm, buttons: ["Cancel", "Close Tab"], destructive: 1 });
  if (choice === 1) await call("terminal", action, id, true);
}
