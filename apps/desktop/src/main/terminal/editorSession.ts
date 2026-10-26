import { existsSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isExecutableFile, PrivateTemporaryDirectory, shellQuote } from "@octo/core/node";

/** A completion marker distinguishes editor startup from exit, even if no socket was created. */
export class EditorSession {
  private readonly directory = new PrivateTemporaryDirectory();
  readonly socket = join(this.directory.path, "nvim.sock");
  readonly completion = join(this.directory.path, "exited");
  /** Created once the PTY has the size the renderer measured for the pane. */
  readonly sized = join(this.directory.path, "sized");
  private marked = false;

  get hasExited(): boolean { return existsSync(this.completion); }

  /** Releases the script to start Neovim at the pane's real size. */
  markSized(): void {
    if (this.marked) return;
    this.marked = true;
    try { writeFileSync(this.sized, ""); } catch { /* disposed */ }
  }

  /**
   * The shell script a pane runs: Neovim, then the user's login shell in the same PTY, even after
   * an editor launch failure. Neovim can miss a resize that lands while it starts and keep drawing
   * at the PTY's initial 80×24, so the script first waits, at most 2 s, for the pane to be sized.
   * Every dynamic value is quoted at this explicit terminal launch boundary.
   */
  script(editor: string, file: string, line: number, shell = loginShell()): string {
    const waitForSize = `i=0; while [ ! -e ${shellQuote(this.sized)} ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done`;
    const editorCommand = [editor, "--listen", this.socket, `+${Math.max(1, line)}`, "--", file].map(shellQuote).join(" ");
    return `${waitForSize}; ${editorCommand}; : > ${shellQuote(this.completion)}; exec ${shellQuote(shell)} -l -i`;
  }

  dispose(): void { this.directory.dispose(); }
}

export function loginShell(): string {
  const shell = process.env.SHELL;
  if (shell?.startsWith("/") && isExecutableFile(shell)) return shell;
  return "/bin/zsh";
}

export function isDirectory(path: string): boolean {
  try { return statSync(path).isDirectory(); } catch { return false; }
}
