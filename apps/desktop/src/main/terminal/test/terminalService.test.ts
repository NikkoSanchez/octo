import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { splitLeaves } from "@octo/core";
import type { TerminalEvent } from "../../../shared/terminal";
import { EditorSession } from "../editorSession";
import { readGhosttyConfig } from "../ghosttyConfig";
import { TerminalService, type PtyProcess } from "../terminalService";

class FakePty implements PtyProcess {
  static count = 0;
  readonly pid = 10_000 + FakePty.count++;
  process = "zsh";
  written: string[] = [];
  sizes: [number, number][] = [];
  paused = false;
  killed: string | undefined;
  private data?: (data: string) => void;
  private exit?: (event: { exitCode: number }) => void;
  constructor(readonly file: string, readonly args: string[], readonly cwd: string, readonly env: Record<string, string>) {}
  onData(listener: (data: string) => void) { this.data = listener; return { dispose() {} }; }
  onExit(listener: (event: { exitCode: number }) => void) { this.exit = listener; return { dispose() {} }; }
  write(data: string) { this.written.push(data); }
  resize(cols: number, rows: number) { this.sizes.push([cols, rows]); }
  pause() { this.paused = true; }
  resume() { this.paused = false; }
  kill(signal?: string) { this.killed = signal ?? "SIGHUP"; queueMicrotask(() => this.end()); }
  emit(data: string) { this.data?.(data); }
  end() { this.exit?.({ exitCode: 0 }); }
}

function setup() {
  const directory = mkdtempSync(join(tmpdir(), "octo-terminal-"));
  const ptys: FakePty[] = [];
  const events: TerminalEvent[] = [];
  const service = new TerminalService({
    spawn: (file, args, options) => { const pty = new FakePty(file, args, options.cwd, options.env); ptys.push(pty); return pty; },
    emit: (event) => events.push(event),
    projectDirectory: (id) => (id === "P" ? directory : undefined),
    ghosttyConfig: () => ({ keybinds: [], unfocusedSplitOpacity: 0.7, diagnostics: [] }),
  });
  return { service, ptys, events, directory };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 20));

describe("terminal workspace", () => {
  it("starts a login shell in the project with Octo's environment, and keeps one tab per ensure", () => {
    const { service, ptys, directory } = setup();
    service.ensureTab("P");
    service.ensureTab("P");
    expect(ptys).toHaveLength(1);
    expect(ptys[0]!.args).toEqual(["-l"]);
    expect(ptys[0]!.cwd).toBe(directory);
    expect(ptys[0]!.env.OCTO_PROJECT_ID).toBe("P");
    expect(ptys[0]!.env.TERM).toBe("xterm-256color");
    expect(Object.keys(ptys[0]!.env).some((k) => k.startsWith("ELECTRON_"))).toBe(false);
    expect(() => service.newTab("missing")).toThrow("no longer exists");
  });

  it("coalesces output per pane, replays it, and pauses until the renderer catches up", async () => {
    const { service, ptys, events } = setup();
    service.newTab("P");
    const pane = service.workspace().tabs[0]!.panes[0]!;
    ptys[0]!.emit("a"); ptys[0]!.emit("b");
    await tick();
    expect(events.filter((e) => e.type === "output")).toEqual([{ type: "output", pane, data: "ab", cursor: 2 }]);
    ptys[0]!.emit("x".repeat(3 * 1024 * 1024));
    expect(ptys[0]!.paused).toBe(true);
    service.ack(pane, 3 * 1024 * 1024);
    expect(ptys[0]!.paused).toBe(false);
    expect(service.snapshot().replay[pane]!.endsWith("x")).toBe(true);
    expect(service.snapshot().replay[pane]!.length).toBeLessThanOrEqual(3 * 1024 * 1024 + 2);
  });

  it("splits beside the focused pane, closes exited panes, and keeps the last one to show its exit", async () => {
    const { service, ptys } = setup();
    const tab = service.newTab("P");
    await service.split(tab, "right");
    let state = service.workspace().tabs[0]!;
    expect(splitLeaves(state.layout)).toEqual(state.panes);
    expect(state.focusedPane).toBe(state.panes[1]);
    ptys[1]!.end();
    state = service.workspace().tabs[0]!;
    expect(state.panes).toHaveLength(1);
    expect(state.focusedPane).toBe(state.panes[0]);
    ptys[0]!.end();
    expect(service.workspace().tabs[0]!.exited).toBe(true);
  });

  it("keeps the remaining pane running when a closed pane's process reports its exit afterwards", async () => {
    const { service, ptys } = setup();
    const tab = service.newTab("P");
    await service.split(tab, "right");
    const [first] = service.workspace().tabs[0]!.panes;
    expect(service.closePane(tab)).toEqual({ closed: true });
    expect(ptys[1]!.killed).toBe("SIGHUP");
    await tick();
    let state = service.workspace().tabs[0]!;
    expect(state.panes).toEqual([first]);
    expect(state.exited).toBe(false);
    await service.split(tab, "down");
    state = service.workspace().tabs[0]!;
    expect(state.panes).toHaveLength(2);
    expect(splitLeaves(state.layout)).toEqual(state.panes);
  });

  it("asks before closing a tab whose program isn't the shell", () => {
    const { service, ptys } = setup();
    const tab = service.newTab("P");
    ptys[0]!.process = "vim";
    expect(service.closeTab(tab)).toEqual({ closed: false, confirm: expect.any(String) });
    expect(service.tabCount("P")).toBe(1);
    expect(service.closeTab(tab, true)).toEqual({ closed: true });
    expect(ptys[0]!.killed).toBe("SIGHUP");
    expect(service.tabCount("P")).toBe(0);
    expect(service.workspace().selected).toEqual({});
  });

  it("cycles tabs and restores the automatic label when a name is cleared", () => {
    const { service } = setup();
    const first = service.newTab("P");
    const second = service.newTab("P");
    service.cycle("P", 1);
    expect(service.workspace().selected.P).toBe(first);
    service.cycle("P", -1);
    expect(service.workspace().selected.P).toBe(second);
    service.rename(first, "  Server ");
    expect(service.workspace().tabs[0]!.customName).toBe("Server");
    service.rename(first, " ");
    expect(service.workspace().tabs[0]!.customName).toBeUndefined();
  });

  it("drops writes and resizes for panes that no longer exist", () => {
    const { service, ptys } = setup();
    service.newTab("P");
    const pane = service.workspace().tabs[0]!.panes[0]!;
    service.write(pane, "ls\r");
    service.resize(pane, 120.7, 40);
    service.write("unknown", "rm -rf /\r");
    expect(ptys[0]!.written).toEqual(["ls\r"]);
    expect(ptys[0]!.sizes).toEqual([[120, 40]]);
  });
});

describe("editor launch", () => {
  it("quotes every dynamic value and returns to a login shell after the editor", () => {
    const session = new EditorSession();
    try {
      const script = session.script("/opt/nvim", "/tmp/it's here.swift", 0, "/bin/zsh");
      expect(script).toContain(`'/opt/nvim' '--listen' '${session.socket}' '+1' '--' '/tmp/it'\\''s here.swift'`);
      expect(script.indexOf(`'${session.sized}'`)).toBeLessThan(script.indexOf("'/opt/nvim'"));
      expect(script.endsWith(`; exec '/bin/zsh' -l -i`)).toBe(true);
      expect(session.hasExited).toBe(false);
    } finally { session.dispose(); }
  });

  it("starts the editor only once the pane has its measured size", async () => {
    const session = new EditorSession();
    const directory = mkdtempSync(join(tmpdir(), "octo-editor-"));
    const editor = join(directory, "editor"), started = join(directory, "started");
    writeFileSync(editor, `#!/bin/sh\n: > '${started}'\n`, { mode: 0o755 });
    try {
      const child = spawn("/bin/sh", ["-c", session.script(editor, directory, 1, "/usr/bin/true")], { stdio: "ignore" });
      const exited = new Promise((resolve) => child.on("exit", resolve));
      await new Promise((resolve) => setTimeout(resolve, 400));
      expect(existsSync(started)).toBe(false);
      session.markSized();
      await exited;
      expect(existsSync(started)).toBe(true);
      expect(session.hasExited).toBe(true);
    } finally { session.dispose(); }
  });

  it("releases an editor when the renderer first sizes its pane", () => {
    const { service, ptys, directory } = setup();
    const bin = mkdtempSync(join(tmpdir(), "octo-bin-"));
    writeFileSync(join(bin, "nvim"), "#!/bin/sh\n", { mode: 0o755 });
    const path = process.env.PATH;
    process.env.PATH = `${bin}:${path}`;
    try { service.openDirectoryInEditor("P", directory); } finally { process.env.PATH = path; }
    const sized = /'([^']+\/sized)'/.exec(ptys[0]!.args[1]!)![1]!;
    const pane = service.workspace().tabs[0]!.panes[0]!;
    expect(existsSync(sized)).toBe(false);
    service.resize(pane, 153, 44);
    expect(ptys[0]!.sizes).toEqual([[153, 44]]);
    expect(existsSync(sized)).toBe(true);
    service.closeProject("P");
  });
});

describe("Ghostty configuration", () => {
  it("reads fonts, keybinds and split styling, following includes", () => {
    const directory = mkdtempSync(join(tmpdir(), "octo-ghostty-"));
    mkdirSync(join(directory, "more"));
    writeFileSync(join(directory, "config"), [
      "# comment", 'font-family = "JetBrains Mono"', "font-size = 14", "keybind = super+d=new_split:right",
      "keybind = ctrl+a>c=new_tab", "unfocused-split-opacity = 0.05", "split-divider-color = 336699", "config-file = more/extra",
      "config-file = ?missing",
    ].join("\n"));
    writeFileSync(join(directory, "more", "extra"), "keybind = super+shift+enter=toggle_split_zoom\nunfocused-split-fill = #112233\n");
    const config = readGhosttyConfig([join(directory, "config")]);
    expect(config.fontFamily).toBe("JetBrains Mono");
    expect(config.fontSize).toBe(14);
    expect(config.keybinds).toEqual([["super+d", "new_split:right"], ["ctrl+a>c", "new_tab"], ["super+shift+enter", "toggle_split_zoom"]]);
    expect(config.unfocusedSplitOpacity).toBe(0.15);
    expect(config.splitDivider).toBe("#336699");
    expect(config.unfocusedSplitFill).toBe("#112233");
    expect(config.diagnostics).toEqual([]);
  });
});
