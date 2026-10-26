import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Apps launched from the Dock inherit launchd's minimal PATH, so CLI lookup appends the common
 * install locations.
 */
export function searchPath(env: NodeJS.ProcessEnv = process.env): string {
  const home = homedir();
  return [env.PATH ?? "", "/opt/homebrew/bin", "/usr/local/bin", join(home, ".local/bin"), join(home, ".bun/bin"), "/usr/bin", "/bin"].join(":");
}

export function isExecutableFile(path: string): boolean {
  try {
    if (!statSync(path).isFile()) return false;
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export function findExecutable(name: string, path = searchPath()): string | undefined {
  for (const directory of path.split(":")) {
    if (!directory) continue;
    const candidate = join(directory, name);
    if (isExecutableFile(candidate)) return candidate;
  }
  return undefined;
}

/** POSIX single-quote shell quoting, for the terminal's explicitly quoted launch boundary only. */
export function shellQuote(value: string): string {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}
