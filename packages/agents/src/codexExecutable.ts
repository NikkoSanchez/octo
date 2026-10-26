import { statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { findExecutable, isExecutableFile, ProcessFailure, runProcess } from "@octo/core/node";

/**
 * One resolution policy for discovery and generation. A user override never silently falls back
 * to a different installation if it disappears.
 */
export const CodexExecutable: {
  bundledPaths(): string[];
  resolve(customPath?: string, bundledPaths?: string[], pathExecutable?: string | null): string | undefined;
  executableAt(path: string): string | undefined;
  version(executable: string): Promise<string>;
} = {
  bundledPaths(): string[] {
    return ["/Applications", join(homedir(), "Applications")].flatMap((root) => [
      `${root}/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`,
      `${root}/Codex.app/Contents/Resources/codex`,
    ]);
  },

  resolve(customPath?: string, bundledPaths?: string[], pathExecutable?: string | null): string | undefined {
    if (customPath !== undefined) return CodexExecutable.executableAt(customPath);
    for (const path of bundledPaths ?? CodexExecutable.bundledPaths()) {
      const found = CodexExecutable.executableAt(path);
      if (found) return found;
    }
    return pathExecutable === undefined ? findExecutable("codex") : (pathExecutable ?? undefined);
  },

  executableAt(path: string): string | undefined {
    if (!path.startsWith("/")) return undefined;
    try { if (statSync(path).isDirectory()) return undefined; } catch { return undefined; }
    return isExecutableFile(path) ? path : undefined;
  },

  async version(executable: string): Promise<string> {
    const result = await runProcess(executable, ["--version"], { directory: dirname(executable) });
    if (result.status !== 0) throw new ProcessFailure("exited", "Could not read Codex version.");
    return result.output.toString("utf8").trim();
  },
};

/** Major.minor at or past `minimum`, from output such as `codex-cli 0.158.0-alpha.2`. */
export function versionAtLeast(version: string, minor: number): boolean {
  const number = version.split(" ").find((part) => /^[0-9]/.test(part));
  if (!number) return false;
  const parts = number.split(".").slice(0, 2).map((p) => Number.parseInt(p, 10));
  if (parts.length !== 2 || parts.some((p) => Number.isNaN(p))) return false;
  return parts[0] > 0 || parts[1] >= minor;
}
