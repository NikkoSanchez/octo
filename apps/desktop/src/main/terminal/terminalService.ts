import { realpathSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import {
  createSplitLayout, equalizeSplits, focusTarget, insertSplit, isSplit, newID, removeSplit, resizeSplit, setSplitRatio,
  splitContains, type Rect, type SplitDirection, type SplitFocusTarget, type SplitLayout,
} from "@octo/core";
import { ClaudeCLI } from "@octo/agents";
import { findExecutable, ProcessFailure, runProcess, searchPath, shellQuote } from "@octo/core/node";
import type {
  CloseResult, GhosttyConfig, TerminalEvent, TerminalSetupState, TerminalSnapshot, TerminalTabState, TerminalWorkspaceState,
} from "../../shared/terminal";
import { EditorSession, isDirectory, loginShell } from "./editorSession";
import { readGhosttyConfig } from "./ghosttyConfig";

export interface PtyProcess {
  readonly pid: number;
  /** The foreground process name. */
  readonly process: string;
  onData(listener: (data: string) => void): { dispose(): void };
  onExit(listener: (event: { exitCode: number; signal?: number }) => void): { dispose(): void };
  write(data: string): void;
  resize(cols: number, rows: number): void;
  pause(): void;
  resume(): void;
  kill(signal?: string): void;
}

export interface PtyOptions { cwd: string; env: Record<string, string>; cols: number; rows: number }
export type SpawnPty = (file: string, args: string[], options: PtyOptions) => PtyProcess;

/** Output is coalesced per pane and sent at most this often, or sooner when this much is waiting. */
const FLUSH_INTERVAL = 8;
const FLUSH_BYTES = 64 * 1024;
/** A pane pauses its PTY while this much output is unacknowledged by the renderer. */
const PAUSE_BYTES = 2 * 1024 * 1024;
const RESUME_BYTES = 512 * 1024;
/** Scrollback kept in main for surfaces that mount late or after a renderer reload. */
const REPLAY_BYTES = 1024 * 1024;

class Pane {
  readonly id = newID();
  readonly shell: string;
  exited = false;
  cursor = 0;
  private pending = "";
  private timer: NodeJS.Timeout | undefined;
  private unacknowledged = 0;
  private paused = false;
  private replay: string[] = [];
  private replayLength = 0;

  constructor(readonly pty: PtyProcess, private readonly emit: (event: TerminalEvent) => void, onExit: () => void) {
    this.shell = basename(loginShell());
    pty.onData((data) => this.receive(data));
    pty.onExit(() => {
      this.flush();
      this.exited = true;
      this.emit({ type: "exit", pane: this.id });
      onExit();
    });
  }

  private receive(data: string): void {
    this.cursor += data.length;
    this.pending += data;
    this.remember(data);
    if (this.pending.length >= FLUSH_BYTES) this.flush();
    else this.timer ??= setTimeout(() => this.flush(), FLUSH_INTERVAL);
  }

  private remember(data: string): void {
    this.replay.push(data);
    this.replayLength += data.length;
    while (this.replayLength > REPLAY_BYTES && this.replay.length > 1) this.replayLength -= this.replay.shift()!.length;
  }

  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (!this.pending) return;
    const data = this.pending;
    this.pending = "";
    this.emit({ type: "output", pane: this.id, data, cursor: this.cursor });
    this.unacknowledged += data.length;
    if (!this.paused && this.unacknowledged > PAUSE_BYTES) { this.paused = true; this.pty.pause(); }
  }

  acknowledge(length: number): void {
    this.unacknowledged = Math.max(0, this.unacknowledged - length);
    if (this.paused && this.unacknowledged < RESUME_BYTES) { this.paused = false; this.pty.resume(); }
  }

  /** A reloaded renderer starts from the replay, so nothing earlier waits on its acknowledgement. */
  snapshot(): string {
    this.flush();
    this.acknowledge(this.unacknowledged);
    return this.replay.join("");
  }

  /** Something other than the shell owns the terminal, so closing would end it. */
  get isBusy(): boolean {
    if (this.exited) return false;
    try { return this.pty.process !== "" && basename(this.pty.process) !== this.shell; } catch { return false; }
  }

  close(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (this.exited) return;
    this.exited = true;
    try { this.pty.kill("SIGHUP"); } catch { /* already gone */ }
  }
}

class Tab {
  readonly id = newID();
  customName?: string;
  exited = false;
  panes: Pane[] = [];
  layout: SplitLayout;
  focusedPane: string;
  readonly primaryPane: string;
  editor?: EditorSession;

  constructor(readonly projectID: string, readonly directory: string, public label: string, primary: Pane, editor?: EditorSession) {
    this.editor = editor;
    this.primaryPane = primary.id;
    this.focusedPane = primary.id;
    this.layout = createSplitLayout(primary.id);
    this.panes.push(primary);
  }

  get title(): string { return this.customName ?? this.label; }
  pane(id: string): Pane | undefined { return this.panes.find((p) => p.id === id); }
  get focused(): Pane { return this.pane(this.focusedPane) ?? this.panes[0]!; }

  /** The editor's completion marker turns the tab back into a plain terminal. */
  refreshEditor(): boolean {
    if (!this.editor?.hasExited) return false;
    this.editor.dispose();
    this.editor = undefined;
    this.label = "Terminal";
    return true;
  }

  state(): TerminalTabState {
    return {
      id: this.id, projectID: this.projectID, directory: this.directory, label: this.label, customName: this.customName,
      exited: this.exited, panes: this.panes.map((p) => p.id), layout: structuredClone(this.layout), focusedPane: this.focusedPane,
      editor: this.editor !== undefined,
    };
  }

  close(): void {
    this.panes.forEach((p) => p.close());
    this.editor?.dispose();
    this.editor = undefined;
  }
}

interface Setup { pane: Pane; title: string; exited: boolean }

/**
 * Every terminal tab and pane, owned by main. A PTY lives until its tab or pane closes, whether or
 * not the renderer shows it, so hiding a tab never ends a shell or editor. Only main spawns.
 */
export class TerminalService {
  private workspaceVersion = 0;
  private tabs: Tab[] = [];
  private selected: Record<string, string> = {};
  private setup: Setup | undefined;
  private editorMonitor: NodeJS.Timeout | undefined;
  private announced = false;

  constructor(private readonly options: {
    spawn: SpawnPty;
    emit: (event: TerminalEvent) => void;
    projectDirectory: (projectID: string) => string | undefined;
    ghosttyConfig?: () => GhosttyConfig;
  }) {}

  // MARK: State

  workspace(): TerminalWorkspaceState {
    const setup: TerminalSetupState | undefined = this.setup && { pane: this.setup.pane.id, title: this.setup.title, exited: this.setup.exited };
    return { version: this.workspaceVersion, tabs: this.tabs.map((t) => t.state()), selected: { ...this.selected }, setup };
  }

  snapshot(): TerminalSnapshot {
    const replay: Record<string, string> = {};
    const cursors: Record<string, number> = {};
    const exited: string[] = [];
    const panes = [...this.tabs.flatMap((t) => t.panes), ...(this.setup ? [this.setup.pane] : [])];
    for (const pane of panes) { replay[pane.id] = pane.snapshot(); cursors[pane.id] = pane.cursor; if (pane.exited) exited.push(pane.id); }
    return { workspace: this.workspace(), replay, cursors, exited };
  }

  /** Coalesced, so a burst of changes sends one workspace event. */
  private changed(): void {
    if (this.announced) return;
    this.announced = true;
    queueMicrotask(() => { this.announced = false; this.workspaceVersion++; this.options.emit({ type: "workspace", workspace: this.workspace() }); });
  }

  private focus(pane: string): void { this.options.emit({ type: "focus", pane }); }

  tabCount(projectID: string): number { return this.tabs.filter((t) => t.projectID === projectID).length; }

  ghosttyConfig(): GhosttyConfig { return (this.options.ghosttyConfig ?? readGhosttyConfig)(); }

  // MARK: Processes

  private environment(projectID?: string): Record<string, string> {
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
      // Electron's own switches would change how a child Node or Electron runs.
      if (value === undefined || key.startsWith("ELECTRON_") || key === "NODE_OPTIONS" || key === "OCTO_USER_DATA" || key === "OCTO_WORKSPACE_PATH") continue;
      env[key] = value;
    }
    env.PATH = searchPath();
    env.TERM = "xterm-256color";
    env.COLORTERM = "truecolor";
    env.TERM_PROGRAM = "Octo";
    env.LANG ??= "en_US.UTF-8";
    if (projectID) env.OCTO_PROJECT_ID = projectID;
    return env;
  }

  /** A login shell, or `/bin/sh -c` running an already-quoted launch script. */
  private spawnPane(directory: string, projectID: string | undefined, script: string | undefined, onExit: (pane: Pane) => void): Pane {
    const shell = loginShell();
    const [file, args] = script ? ["/bin/sh", ["-c", script]] as const : [shell, ["-l"]] as const;
    const pty = this.options.spawn(file, [...args], { cwd: isDirectory(directory) ? directory : homedir(), env: this.environment(projectID), cols: 80, rows: 24 });
    const pane: Pane = new Pane(pty, this.options.emit, () => onExit(pane));
    return pane;
  }

  private makeTab(projectID: string, directory: string, label: string, script?: string, editor?: EditorSession): Tab {
    let tab: Tab | undefined;
    const primary = this.spawnPane(directory, projectID, script, (pane) => { if (tab) this.paneExited(tab, pane.id); });
    tab = new Tab(projectID, directory, label, primary, editor);
    this.tabs.push(tab);
    if (editor) this.watchEditors();
    return tab;
  }

  private watchEditors(): void {
    this.editorMonitor ??= setInterval(() => {
      let any = false;
      for (const tab of this.tabs) { if (tab.refreshEditor()) this.changed(); if (tab.editor) any = true; }
      if (!any) { clearInterval(this.editorMonitor); this.editorMonitor = undefined; }
    }, 250);
  }

  /**
   * A pane whose process ends closes, as in Ghostty; the tab's last pane stays to show it exited.
   * Close Pane removes its pane before the process reports the exit, so that later report is ignored.
   */
  private paneExited(tab: Tab, id: string): void {
    if (!this.tabs.includes(tab) || !tab.pane(id)) return;
    if (id === tab.primaryPane && tab.editor) {
      tab.editor.dispose(); tab.editor = undefined;
      if (isSplit(tab.layout)) tab.label = "Terminal";
    }
    if (!isSplit(tab.layout)) { tab.exited = true; this.changed(); return; }
    const next = focusTarget(tab.layout, "previous", id);
    removeSplit(tab.layout, id);
    tab.panes = tab.panes.filter((p) => p.id !== id);
    if (tab.focusedPane === id && next) { tab.focusedPane = next; this.focus(next); }
    this.changed();
  }

  // MARK: Tabs

  private tab(id: string): Tab {
    const tab = this.tabs.find((t) => t.id === id);
    if (!tab) throw new Error("This terminal tab has closed.");
    return tab;
  }

  private directoryFor(projectID: string): string {
    const directory = this.options.projectDirectory(projectID);
    if (!directory) throw new Error("This project no longer exists.");
    return directory;
  }

  newTab(projectID: string): string {
    const tab = this.makeTab(projectID, this.directoryFor(projectID), "Terminal");
    this.selected[projectID] = tab.id;
    this.focus(tab.focusedPane);
    this.changed();
    return tab.id;
  }

  ensureTab(projectID: string): void {
    if (!this.tabs.some((t) => t.projectID === projectID)) this.newTab(projectID);
  }

  select(tabID: string): void {
    const tab = this.tab(tabID);
    this.selected[tab.projectID] = tab.id;
    this.focus(tab.focusedPane);
    this.changed();
  }

  cycle(projectID: string, offset: number): void {
    const candidates = this.tabs.filter((t) => t.projectID === projectID);
    if (candidates.length === 0) return;
    const current = Math.max(0, candidates.findIndex((t) => t.id === this.selected[projectID]));
    this.select(candidates[(current + offset + candidates.length * Math.abs(offset)) % candidates.length]!.id);
  }

  /** A blank name restores the automatic label. */
  rename(tabID: string, name: string): void {
    const tab = this.tab(tabID);
    const trimmed = name.trim();
    tab.customName = trimmed || undefined;
    this.changed();
  }

  /** Asks first when a program other than the shell is running, as the tab's close button does. */
  closeTab(tabID: string, confirmed = false): CloseResult {
    const tab = this.tabs.find((t) => t.id === tabID);
    if (!tab) return { closed: true };
    if (!confirmed && tab.panes.some((p) => p.isBusy)) return { closed: false, confirm: "Closing ends the shell and the programs running in it." };
    tab.close();
    this.tabs = this.tabs.filter((t) => t !== tab);
    const remaining = this.tabs.filter((t) => t.projectID === tab.projectID);
    if (remaining.length) this.selected[tab.projectID] = remaining.at(-1)!.id; else delete this.selected[tab.projectID];
    this.changed();
    return { closed: true };
  }

  /** Ends every tab of a removed project. */
  closeProject(projectID: string): void {
    for (const tab of this.tabs.filter((t) => t.projectID === projectID)) tab.close();
    this.tabs = this.tabs.filter((t) => t.projectID !== projectID);
    delete this.selected[projectID];
    this.changed();
  }

  // MARK: Panes

  write(pane: string, data: string): void { this.findPane(pane)?.pty.write(data); }

  resize(pane: string, cols: number, rows: number): void {
    const target = this.findPane(pane);
    if (!target || target.exited || !(cols > 0 && rows > 0)) return;
    try { target.pty.resize(Math.min(1000, Math.floor(cols)), Math.min(1000, Math.floor(rows))); } catch { /* exited */ }
    this.tabs.find((t) => t.primaryPane === pane)?.editor?.markSized();
  }

  ack(pane: string, length: number): void { this.findPane(pane)?.acknowledge(length); }

  private findPane(id: string): Pane | undefined {
    if (this.setup?.pane.id === id) return this.setup.pane;
    for (const tab of this.tabs) { const pane = tab.pane(id); if (pane) return pane; }
    return undefined;
  }

  /** The shell's current directory, which a new split starts in as Ghostty's `new_split` does. */
  private async workingDirectory(pane: Pane): Promise<string | undefined> {
    try {
      if (process.platform === "linux") return realpathSync(`/proc/${pane.pty.pid}/cwd`);
      const lsof = findExecutable("lsof") ?? "/usr/sbin/lsof";
      const result = await runProcess(lsof, ["-a", "-p", String(pane.pty.pid), "-d", "cwd", "-Fn"], { directory: "/", timeout: 5, outputLimit: 64_000 });
      const line = result.output.toString("utf8").split("\n").find((l) => l.startsWith("n"));
      const path = line?.slice(1);
      return path && isDirectory(path) ? path : undefined;
    } catch { return undefined; }
  }

  async split(tabID: string, direction: SplitDirection): Promise<void> {
    const tab = this.tab(tabID);
    if (tab.exited) return;
    const from = tab.focusedPane;
    const directory = (await this.workingDirectory(tab.focused)) ?? tab.directory;
    if (!this.tabs.includes(tab) || tab.exited || !splitContains(tab.layout, from)) return;
    const pane = this.spawnPane(directory, tab.projectID, undefined, (p) => this.paneExited(tab, p.id));
    tab.panes.push(pane);
    insertSplit(tab.layout, pane.id, from, direction);
    tab.focusedPane = pane.id;
    this.focus(pane.id);
    this.changed();
  }

  closePane(tabID: string, confirmed = false): CloseResult {
    const tab = this.tab(tabID);
    const pane = tab.focused;
    if (!confirmed && pane.isBusy) return { closed: false, confirm: "Closing ends the shell and the programs running in it." };
    if (!isSplit(tab.layout)) return this.closeTab(tabID, true);
    pane.close();
    this.paneExited(tab, pane.id);
    return { closed: true };
  }

  focusPane(tabID: string, pane: string): void {
    const tab = this.tab(tabID);
    if (tab.focusedPane === pane || !tab.pane(pane)) return;
    tab.focusedPane = pane;
    this.changed();
  }

  focusDirection(tabID: string, target: SplitFocusTarget): void {
    const tab = this.tab(tabID);
    const next = focusTarget(tab.layout, target, tab.focusedPane);
    if (!next) return;
    tab.layout.zoomed = null;
    tab.focusedPane = next;
    this.focus(next);
    this.changed();
  }

  toggleZoom(tabID: string): void {
    const tab = this.tab(tabID);
    if (!isSplit(tab.layout)) return;
    tab.layout.zoomed = tab.layout.zoomed === tab.focusedPane ? null : tab.focusedPane;
    this.focus(tab.focusedPane);
    this.changed();
  }

  equalize(tabID: string): void { equalizeSplits(this.tab(tabID).layout); this.changed(); }

  setRatio(tabID: string, ratio: number, path: number[]): void { setSplitRatio(this.tab(tabID).layout, ratio, path); this.changed(); }

  /** Ghostty's point-based `resize_split`, against the size the renderer laid the tab out at. */
  resizePane(tabID: string, direction: SplitDirection, points: number, bounds: Rect): void {
    const tab = this.tab(tabID);
    if (bounds.width <= 0 || bounds.height <= 0) return;
    if (resizeSplit(tab.layout, tab.focusedPane, direction, points, bounds)) this.changed();
  }

  // MARK: Editor

  private nvim(): string {
    const nvim = findExecutable("nvim");
    if (!nvim) throw new ProcessFailure("missing", "nvim (Open in Neovim uses your installed Neovim and its configuration)");
    return nvim;
  }

  private runningEditor(projectID: string, directory: string): Tab | undefined {
    for (const tab of this.tabs) if (tab.refreshEditor()) this.changed();
    return this.tabs.find((t) => t.projectID === projectID && t.directory === directory && t.editor && !t.exited);
  }

  /** Opening a file belongs in the editor's pane, not a shell split beside it. */
  private focusEditorPane(tab: Tab): void {
    if (!tab.editor || !splitContains(tab.layout, tab.primaryPane)) return;
    if (tab.layout.zoomed !== tab.primaryPane) tab.layout.zoomed = null;
    tab.focusedPane = tab.primaryPane;
  }

  /**
   * Opens a checkout file in this checkout's running Neovim through its socket, or starts Neovim in
   * a new tab. RPC talks only to an editor Octo launched; it never types into a busy shell.
   */
  async openInEditor(projectID: string, directory: string, relativePath: string, line = 1): Promise<void> {
    const nvim = this.nvim();
    let root: string, file: string;
    try { root = realpathSync(directory); file = realpathSync(`${root}/${relativePath}`); } catch {
      throw new ProcessFailure("exited", "The selected file no longer exists in this checkout.");
    }
    if (!file.startsWith(root + "/") || !existsSync(file)) throw new ProcessFailure("exited", "The selected file no longer exists in this checkout.");
    const running = this.runningEditor(projectID, directory);
    if (running?.editor) {
      const pathJSON = JSON.stringify([file]).replaceAll("'", "''");
      const target = Math.max(1, Math.floor(line));
      const expression = `luaeval('(function() vim.cmd.edit(vim.fn.fnameescape(_A[1])); vim.api.nvim_win_set_cursor(0, {math.min(${target}, vim.api.nvim_buf_line_count(0)), 0}); return 1 end)()', json_decode('${pathJSON}'))`;
      const result = await runProcess(nvim, ["--server", running.editor.socket, "--remote-expr", expression], { directory: root });
      if (!this.tabs.includes(running)) return;
      running.refreshEditor();
      if (running.editor && !running.exited) {
        if (result.status !== 0) throw new ProcessFailure("exited", "The editor tab is not ready or could not open the file. " + result.error.toString("utf8"));
        running.label = basename(file);
        this.focusEditorPane(running);
        this.select(running.id);
        return;
      }
    }
    const session = new EditorSession();
    const tab = this.makeTab(projectID, directory, basename(file), session.script(nvim, file, line), session);
    this.select(tab.id);
  }

  /** Selects this checkout's running editor tab, or starts Neovim on the checkout root. */
  openDirectoryInEditor(projectID: string, directory: string): void {
    const nvim = this.nvim();
    let root: string;
    try { root = realpathSync(directory); } catch { throw new ProcessFailure("exited", "This checkout no longer exists."); }
    if (!isDirectory(root)) throw new ProcessFailure("exited", "This checkout no longer exists.");
    const running = this.runningEditor(projectID, directory);
    if (running) { this.focusEditorPane(running); this.select(running.id); return; }
    const session = new EditorSession();
    const tab = this.makeTab(projectID, directory, basename(root), session.script(nvim, root, 1), session);
    this.select(tab.id);
  }

  // MARK: CLI setup

  /**
   * A dedicated terminal for an explicitly requested CLI setup command, such as Claude's sign-in.
   * It never writes into an existing shell and never reads the terminal's output for credentials.
   */
  openCLISetup(kind: "claudeLogin"): void {
    if (kind !== "claudeLogin") throw new Error("Unknown setup command.");
    const claude = findExecutable("claude");
    if (!claude) throw new ProcessFailure("missing", "Claude CLI");
    this.closeSetup();
    const script = [claude, ...ClaudeCLI.loginArguments].map(shellQuote).join(" ");
    const pane: Pane = this.spawnPane(homedir(), undefined, script, () => {
      if (this.setup?.pane === pane) { this.setup.exited = true; this.changed(); }
    });
    this.setup = { pane, title: "Sign in through Claude CLI", exited: false };
    this.focus(pane.id);
    this.changed();
  }

  closeSetup(): void {
    if (!this.setup) return;
    this.setup.pane.close();
    this.setup = undefined;
    this.changed();
  }

  shutdown(): void {
    if (this.editorMonitor) clearInterval(this.editorMonitor);
    this.editorMonitor = undefined;
    this.tabs.forEach((t) => t.close());
    this.tabs = [];
    this.selected = {};
    this.setup?.pane.close();
    this.setup = undefined;
  }
}
