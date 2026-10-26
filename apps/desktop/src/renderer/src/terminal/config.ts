import { APP_THEMES, themeTitle, type AppTheme } from "@octo/core";
import type { GhosttyConfig } from "../../../shared/terminal";
import { resolveTheme } from "../theme/theme";
import type { GhosttyTheme, GhosttyColor } from "./ghostty/core";
export const color = (value: string): GhosttyColor => { const n = parseInt(value.replace(/^#/, ""), 16); return { r: n >> 16 & 255, g: n >> 8 & 255, b: n & 255 }; };
export function mappedGhosttyTheme(value: string | undefined, dark: boolean): AppTheme | undefined {
  let name = value;
  if (name?.includes("light:") || name?.includes("dark:")) name = name.split(",").find((part) => part.trim().startsWith(dark ? "dark:" : "light:"))?.split(":").slice(1).join(":").trim();
  const normalize = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  return name ? APP_THEMES.find((t) => normalize(t) === normalize(name!) || normalize(themeTitle(t)) === normalize(name!)) : undefined;
}
export function terminalTheme(theme: AppTheme, dark: boolean, config?: GhosttyConfig): GhosttyTheme {
  const mapped = mappedGhosttyTheme(config?.theme, dark);
  const { palette: p } = resolveTheme(mapped ?? theme, { dark });
  return { foreground: color(p.text), background: color(p.base), cursor: color(p.cursor), palette: p.ansi.map(color), selectionBackground: `#${p.terminalSelectionBackground}` };
}
export function bindingMatches(event: KeyboardEvent, trigger: string): boolean {
  if (trigger.includes(":")) return false;
  const parts = trigger.toLowerCase().split("+");
  const key = parts.pop();
  return (key === event.key.toLowerCase() || key === event.code.toLowerCase().replace(/^key|^digit/, "")) &&
    event.metaKey === parts.some((p) => ["super", "cmd", "command"].includes(p)) && event.ctrlKey === parts.some((p) => ["ctrl", "control"].includes(p)) && event.altKey === parts.some((p) => ["alt", "opt", "option"].includes(p)) && event.shiftKey === parts.includes("shift");
}
