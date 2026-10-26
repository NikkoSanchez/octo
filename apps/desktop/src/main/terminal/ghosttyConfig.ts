import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import type { GhosttyConfig } from "../../shared/terminal";

/** Ghostty's own search order on macOS: XDG first, then the app's support folder. */
export function ghosttyConfigPaths(home = homedir(), env: NodeJS.ProcessEnv = process.env): string[] {
  const xdg = env.XDG_CONFIG_HOME ? join(env.XDG_CONFIG_HOME, "ghostty") : join(home, ".config", "ghostty");
  const paths = [join(xdg, "config"), join(xdg, "config.ghostty")];
  if (process.platform === "darwin") {
    const support = join(home, "Library", "Application Support", "com.mitchellh.ghostty");
    paths.push(join(support, "config"), join(support, "config.ghostty"));
  }
  return paths;
}

const COLOR = /^#?[0-9a-fA-F]{6}$/;

/**
 * Reads the keys Octo's web terminal can honor from the user's Ghostty files, following
 * `config-file` includes. Unknown keys are ignored; Ghostty itself is never run.
 */
export function readGhosttyConfig(paths = ghosttyConfigPaths()): GhosttyConfig {
  const config: GhosttyConfig = { keybinds: [], unfocusedSplitOpacity: 0.7, diagnostics: [] };
  const seen = new Set<string>();
  const load = (path: string, optional: boolean, depth: number) => {
    const absolute = resolve(path);
    if (seen.has(absolute) || depth > 8) return;
    seen.add(absolute);
    let text: string;
    try { text = readFileSync(absolute, "utf8"); } catch {
      if (!optional) config.diagnostics.push(`${absolute}: cannot read included file`);
      return;
    }
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const index = line.indexOf("=");
      if (index < 0) continue;
      const key = line.slice(0, index).trim();
      let value = line.slice(index + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
      switch (key) {
        case "theme": if (value) config.theme = value; else delete config.theme; break;
        case "font-family": if (value) config.fontFamily = value; else delete config.fontFamily; break;
        case "font-size": { const size = Number(value); if (Number.isFinite(size) && size > 0) config.fontSize = size; break; }
        case "keybind": {
          if (value === "clear") { config.keybinds = []; break; }
          const split = value.lastIndexOf("=");
          if (split > 0) config.keybinds.push([value.slice(0, split).trim(), value.slice(split + 1).trim()]);
          break;
        }
        case "unfocused-split-opacity": {
          const opacity = Number(value);
          if (Number.isFinite(opacity)) config.unfocusedSplitOpacity = Math.min(1, Math.max(0.15, opacity));
          break;
        }
        case "unfocused-split-fill": if (COLOR.test(value)) config.unfocusedSplitFill = value.startsWith("#") ? value : `#${value}`; break;
        case "split-divider-color": if (COLOR.test(value)) config.splitDivider = value.startsWith("#") ? value : `#${value}`; break;
        case "config-file": {
          const optionalInclude = value.startsWith("?");
          const target = optionalInclude ? value.slice(1) : value;
          if (target) load(isAbsolute(target) ? target : join(dirname(absolute), target), optionalInclude, depth + 1);
          break;
        }
      }
    }
  };
  for (const path of paths) load(path, true, 0);
  return config;
}
