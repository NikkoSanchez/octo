import { composite, themePalette, themeSyntax, type AppTheme, type ThemePalette, type ThemeSyntaxPalette } from "@octo/core";

export interface SystemAppearance { dark: boolean; accent?: string }

const hex = (value: string) => `#${value}`;
function rgba(value: string, alpha: number): string {
  const n = parseInt(value, 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

function luminance(value: string): number {
  const n = parseInt(value, 16);
  const linear = (channel: number) => { const c = channel / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * linear((n >> 16) & 255) + 0.7152 * linear((n >> 8) & 255) + 0.0722 * linear(n & 255);
}

/** The WCAG contrast ratio of two opaque colours. */
export function contrastRatio(a: string, b: string): number {
  const [lighter, darker] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (lighter + 0.05) / (darker + 0.05);
}

/** Field and control outlines stand this far from the panel behind them in every theme. */
export const CONTROL_BORDER_CONTRAST = 1.8;

/**
 * The least opacity of `ink` over `surface` that reaches `target` contrast. Themes' text contrast
 * varies widely, so one fixed opacity drew outlines that vanished in some themes.
 */
export function inkOpacity(ink: string, surface: string, target: number): number {
  for (let percent = 10; percent < 100; percent += 2) {
    if (contrastRatio(composite(ink, percent / 100, surface), surface) >= target) return percent / 100;
  }
  return 1;
}

/**
 * The System theme's roles: macOS's own window, control and label colours, approximated, with
 * the user's accent colour.
 */
function systemPalette(dark: boolean, accent = "007aff"): ThemePalette {
  return dark ? {
    isDark: true, base: "1e1e1e", mantle: "262626", crust: "1a1a1a", surface: "3a3a3c", overlay0: "4a4a4c", overlay1: "8e8e93", overlay2: "aeaeb2",
    text: "f2f2f7", secondary: "98989f", accent, green: "32d74b", red: "ff453a", yellow: "ffd60a", blue: "0a84ff", teal: "64d2ff", orange: "ff9f0a",
    activeBorder: accent, onAccent: "ffffff", listSelection: accent, listSelectionText: "ffffff", cursor: "f2f2f7", cursorText: "1e1e1e",
    selectionBackground: accent, selectionOpacity: 0.35, terminalSelectionBackground: composite(accent, 0.35, "1e1e1e"),
    lineHighlight: "ffffff", lineHighlightOpacity: 0.06, diffLineOpacity: 0.2,
    ansi: ["1e1e1e", "ff453a", "32d74b", "ffd60a", "0a84ff", "bf5af2", "64d2ff", "d1d1d6", "636366", "ff6961", "4ae168", "ffe55c", "409cff", "da8fff", "8ad8ff", "ffffff"],
  } : {
    isDark: false, base: "ffffff", mantle: "f5f5f7", crust: "ececec", surface: "e8e8ed", overlay0: "d1d1d6", overlay1: "8e8e93", overlay2: "636366",
    text: "1d1d1f", secondary: "6e6e73", accent, green: "28a745", red: "d70015", yellow: "b25000", blue: "0066cc", teal: "0071a4", orange: "c93400",
    activeBorder: accent, onAccent: "ffffff", listSelection: accent, listSelectionText: "ffffff", cursor: "1d1d1f", cursorText: "ffffff",
    selectionBackground: accent, selectionOpacity: 0.25, terminalSelectionBackground: composite(accent, 0.25, "ffffff"),
    lineHighlight: "000000", lineHighlightOpacity: 0.05, diffLineOpacity: 0.16,
    ansi: ["1d1d1f", "c41a16", "1d8a2c", "a05a00", "0b4fd6", "8a32b5", "00788f", "d1d1d6", "6e6e73", "e0291f", "28a745", "c26e00", "2f6fe8", "a64fd4", "0094b3", "ffffff"],
  };
}

const SYSTEM_SYNTAX_LIGHT: ThemeSyntaxPalette = {
  keyword: "9b2393", string: "c41a16", escape: "c41a16", comment: "5d6c79", number: "1c00cf", function: "326d74", key: "0b4f79",
  punctuation: "1d1d1f", operatorColor: "1d1d1f", builtin: "9b2393", hunk: "1c00cf", diffFile: "326d74", diffPath: "9b2393", italic: ["comment"],
};
const SYSTEM_SYNTAX_DARK: ThemeSyntaxPalette = {
  keyword: "fc5fa3", string: "fc6a5d", escape: "fc6a5d", comment: "7f8c98", number: "d0bf69", function: "67b7a4", key: "5dd8ff",
  punctuation: "f2f2f7", operatorColor: "f2f2f7", builtin: "fc5fa3", hunk: "d0bf69", diffFile: "67b7a4", diffPath: "fc5fa3", italic: ["comment"],
};

export interface ResolvedTheme { palette: ThemePalette; syntax: ThemeSyntaxPalette; isSystem: boolean }

export function resolveTheme(theme: AppTheme, system: SystemAppearance): ResolvedTheme {
  const palette = themePalette(theme);
  if (palette) return { palette, syntax: themeSyntax(theme)!, isSystem: false };
  return { palette: systemPalette(system.dark, system.accent), syntax: system.dark ? SYSTEM_SYNTAX_DARK : SYSTEM_SYNTAX_LIGHT, isSystem: true };
}

/** The theme's roles as CSS custom properties. */
export function themeVariables({ palette: p, syntax, isSystem }: ResolvedTheme): Record<string, string> {
  const dark = p.isDark;
  return {
    "--background": hex(p.base),
    "--panel": hex(p.mantle),
    "--crust": hex(p.crust),
    "--foreground": hex(p.text),
    // Full-strength light text blooms on a dark base, so paragraphs step down.
    "--prose": !isSystem && dark ? rgba(p.text, 0.82) : hex(p.text),
    "--secondary": hex(p.secondary),
    "--subtle": hex(p.overlay1),
    "--accent": hex(p.accent),
    "--accent-soft": rgba(p.accent, 0.12),
    "--accent-softer": rgba(p.accent, 0.2),
    "--surface": hex(p.surface),
    "--blue": hex(p.blue), "--green": hex(p.green), "--red": hex(p.red), "--yellow": hex(p.yellow), "--teal": hex(p.teal), "--orange": hex(p.orange),
    "--selection": rgba(p.selectionBackground, p.selectionOpacity),
    "--on-accent": hex(p.onAccent),
    "--border": hex(p.overlay0),
    "--active-border": hex(p.activeBorder),
    "--row-selection": hex(p.listSelection),
    "--on-row-selection": hex(p.listSelectionText),
    "--on-row-selection-secondary": rgba(p.listSelectionText, 0.8),
    "--hairline": rgba(p.overlay0, isSystem ? 0.6 : 0.3),
    "--field": rgba(p.surface, 0.7),
    "--glass": rgba(p.mantle, isSystem ? 0.72 : 0.86),
    "--wash": dark ? "rgba(255, 255, 255, 1)" : "rgba(0, 0, 0, 1)",
    "--hover": dark ? "rgba(255, 255, 255, 0.07)" : "rgba(0, 0, 0, 0.06)",
    "--press": dark ? "rgba(255, 255, 255, 0.12)" : "rgba(0, 0, 0, 0.12)",
    // The monogram circle behind provider marks, after Messages' contact avatars.
    "--avatar-top": isSystem ? (dark ? "#6f7489" : "#a9afc6") : hex(dark ? p.overlay0 : p.surface),
    "--avatar-bottom": isSystem ? (dark ? "#51556a" : "#858aa2") : hex(dark ? p.surface : p.overlay0),
    "--avatar-foreground": isSystem ? "#ffffff" : hex(dark ? p.text : p.base),
    "--card-shadow": dark ? "rgba(0, 0, 0, 0.3)" : "rgba(0, 0, 0, 0.07)",
    "--rim-outer": dark ? "rgba(0, 0, 0, 0.55)" : "rgba(0, 0, 0, 0.13)",
    "--rim-inner": dark ? "rgba(255, 255, 255, 0.16)" : "rgba(255, 255, 255, 0.75)",
    // Text fields and small glass controls. Glass cards keep the dark rim above, but on a field or a
    // capsule in a dark theme that rim drew black, or nothing at all.
    "--control-border": rgba(p.text, inkOpacity(p.text, p.mantle, CONTROL_BORDER_CONTRAST)),
    "--cursor": hex(p.cursor),
    "--line-highlight": rgba(p.lineHighlight, p.lineHighlightOpacity),
    "--diff-added": rgba(p.green, p.diffLineOpacity),
    "--diff-removed": rgba(p.red, p.diffLineOpacity),
    // The message ⌘G is on; System uses the accent.
    "--search-highlight": isSystem ? rgba(p.accent, 0.2) : rgba(p.findCurrent ?? p.red, 0.2),
    // Occurrences, for themes with their own find colours (Catppuccin: Red current, Sky others).
    "--find-current": rgba(p.findCurrent ?? p.red, 0.3),
    "--find-other": rgba(p.findOther ?? p.teal, 0.3),
    "--syntax-keyword": hex(syntax.keyword), "--syntax-string": hex(syntax.string), "--syntax-comment": hex(syntax.comment),
    "--syntax-number": hex(syntax.number), "--syntax-function": hex(syntax.function), "--syntax-key": hex(syntax.key),
    "--syntax-hunk": hex(syntax.hunk),
    "color-scheme": dark ? "dark" : "light",
  };
}

export function applyTheme(resolved: ResolvedTheme): void {
  const root = document.documentElement;
  for (const [name, value] of Object.entries(themeVariables(resolved))) {
    if (name === "color-scheme") root.style.colorScheme = value; else root.style.setProperty(name, value);
  }
  root.dataset.dark = resolved.palette.isDark ? "true" : "false";
  root.dataset.findColors = String(!resolved.isSystem && !!resolved.palette.findCurrent && !!resolved.palette.findOther);
}
