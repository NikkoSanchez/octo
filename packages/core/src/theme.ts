/** The app's colour themes. Raw values are persisted; never rename an existing value. */
export type AppTheme =
  | "system" | "latte" | "frappe" | "macchiato" | "mocha" | "dracula" | "githubLight" | "githubDark"
  | "gruvboxLight" | "gruvboxDark" | "nord" | "oneLight" | "oneDark" | "rosePineDawn" | "rosePine"
  | "solarizedLight" | "solarizedDark" | "tokyoNightDay" | "tokyoNight";

export const APP_THEMES: readonly AppTheme[] = [
  "system", "latte", "frappe", "macchiato", "mocha", "dracula", "githubLight", "githubDark", "gruvboxLight", "gruvboxDark",
  "nord", "oneLight", "oneDark", "rosePineDawn", "rosePine", "solarizedLight", "solarizedDark", "tokyoNightDay", "tokyoNight",
];

const TITLES: Record<AppTheme, string> = {
  system: "macOS System", latte: "Catppuccin Latte", frappe: "Catppuccin Frappé", macchiato: "Catppuccin Macchiato",
  mocha: "Catppuccin Mocha", dracula: "Dracula Classic", githubLight: "GitHub Light", githubDark: "GitHub Dark",
  gruvboxLight: "Gruvbox Light", gruvboxDark: "Gruvbox Dark", nord: "Nord", oneLight: "One Light", oneDark: "One Dark",
  rosePineDawn: "Rosé Pine Dawn", rosePine: "Rosé Pine", solarizedLight: "Solarized Light", solarizedDark: "Solarized Dark",
  tokyoNightDay: "Tokyo Night Day", tokyoNight: "Tokyo Night",
};

export function themeTitle(theme: AppTheme): string {
  return TITLES[theme];
}

export function isAppTheme(value: unknown): value is AppTheme {
  return typeof value === "string" && (APP_THEMES as readonly string[]).includes(value);
}

/** Lexical token classes the review highlighter recognizes. */
export type SyntaxRole = "keyword" | "string" | "escape" | "comment" | "number" | "function" | "key" | "punctuation" | "operatorSymbol" | "builtin";

export interface ThemeSyntaxPalette {
  keyword: string; string: string; escape: string; comment: string; number: string;
  function: string; key: string; punctuation: string; operatorColor: string;
  /** `self`, `this`, `super`. */
  builtin: string;
  /** Diff header lines: `@@` hunks, `diff --git` and `---`/`+++` paths. Other headers use comment. */
  hunk: string; diffFile: string; diffPath: string;
  italic: SyntaxRole[];
}

export function syntaxColor(palette: ThemeSyntaxPalette, role: SyntaxRole): string {
  return role === "operatorSymbol" ? palette.operatorColor : palette[role];
}

/**
 * Semantic UI roles, named after Catppuccin's ladder (Base → Mantle → Crust for panes, Surface
 * for controls, Overlay 0–2 for borders and subtle text). Colors are six-digit hex without `#`.
 */
export interface ThemePalette {
  isDark: boolean;
  base: string; mantle: string; crust: string; surface: string;
  overlay0: string; overlay1: string; overlay2: string; text: string; secondary: string;
  accent: string; green: string; red: string; yellow: string; blue: string; teal: string; orange: string;
  /** Focused borders. */
  activeBorder: string;
  /** Text and icons on an accent fill. */
  onAccent: string;
  /** Selected list rows (sidebar threads) and their text. */
  listSelection: string; listSelectionText: string;
  cursor: string; cursorText: string;
  selectionBackground: string; selectionOpacity: number;
  /** The terminal takes opaque RGB, so translucent selections are precomposed over Base. */
  terminalSelectionBackground: string;
  /** Hovered source lines are drawn over the text, so this is always translucent. */
  lineHighlight: string; lineHighlightOpacity: number;
  /** Opacity of added/deleted line backgrounds in diffs. */
  diffLineOpacity: number;
  /** Find highlights: the current match and other matches. Undefined keeps the default. */
  findCurrent?: string; findOther?: string;
  /** Terminal palette in index order: ANSI 0–15, then any extended slots the theme defines. */
  ansi: string[];
}

/** `top` at `opacity` over `bottom`, as six-digit hex. */
export function composite(top: string, opacity: number, bottom: string): string {
  const t = parseInt(top, 16), b = parseInt(bottom, 16);
  if (Number.isNaN(t) || Number.isNaN(b)) return top;
  return [16, 8, 0].map((shift) => {
    const value = ((t >> shift) & 255) * opacity + ((b >> shift) & 255) * (1 - opacity);
    return Math.round(value).toString(16).padStart(2, "0");
  }).join("");
}

type PaletteInput = Omit<ThemePalette, "crust" | "activeBorder" | "onAccent" | "listSelection" | "listSelectionText" | "cursorText" |
  "selectionOpacity" | "terminalSelectionBackground" | "lineHighlight" | "lineHighlightOpacity" | "diffLineOpacity"> &
  Partial<Pick<ThemePalette, "crust" | "activeBorder" | "onAccent" | "listSelection" | "listSelectionText" | "cursorText" |
  "selectionOpacity" | "terminalSelectionBackground" | "lineHighlight" | "lineHighlightOpacity" | "diffLineOpacity">>;

export function makePalette(p: PaletteInput): ThemePalette {
  const selectionOpacity = p.selectionOpacity ?? 1;
  return {
    ...p,
    crust: p.crust ?? p.mantle,
    activeBorder: p.activeBorder ?? p.accent,
    onAccent: p.onAccent ?? p.base,
    listSelection: p.listSelection ?? p.accent,
    listSelectionText: p.listSelectionText ?? p.onAccent ?? p.base,
    cursorText: p.cursorText ?? p.base,
    selectionOpacity,
    terminalSelectionBackground: p.terminalSelectionBackground ?? composite(p.selectionBackground, selectionOpacity, p.base),
    lineHighlight: p.lineHighlight ?? p.text,
    lineHighlightOpacity: p.lineHighlightOpacity ?? 0.08,
    diffLineOpacity: p.diffLineOpacity ?? 0.2,
  };
}

type SyntaxInput = Omit<ThemeSyntaxPalette, "hunk" | "diffFile" | "diffPath" | "italic"> &
  Partial<Pick<ThemeSyntaxPalette, "hunk" | "diffFile" | "diffPath" | "italic">>;

export function makeSyntax(s: SyntaxInput): ThemeSyntaxPalette {
  return { ...s, hunk: s.hunk ?? s.number, diffFile: s.diffFile ?? s.function, diffPath: s.diffPath ?? s.keyword, italic: s.italic ?? [] };
}
