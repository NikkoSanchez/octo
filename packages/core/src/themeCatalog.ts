import { composite, makePalette, makeSyntax, type AppTheme, type ThemePalette, type ThemeSyntaxPalette } from "./theme";

// Palettes come from each theme's upstream source (reviewed October 20, 2026). UI roles map the
// theme's own background/surface/text ladder; syntax roles follow its editor port; terminal colors
// follow its official terminal port where one exists. See docs/KEYBOARD.md#themes.

/**
 * Catppuccin palette 1.8.0. Roles follow the official VS Code port where it is more specific than
 * the style guide (list selection, on-accent text, selection/line/diff opacities, operators).
 * Selected sidebar rows follow the Zed port (`ghost_element.selected`), whose rows are easier to see.
 */
interface Catppuccin {
  isDark: boolean;
  rosewater: string; pink: string; mauve: string; red: string; peach: string; yellow: string; green: string;
  teal: string; sky: string; blue: string; lavender: string;
  text: string; subtext0: string; overlay2: string; overlay1: string; overlay0: string; surface2: string;
  surface0: string; base: string; mantle: string; crust: string;
  /** Official normal and bright ANSI colors (0–15). */
  ansi: string[];
  /** The Zed port's selected list row, drawn at 40%. */
  rowSelection: string;
}

function catppuccinPalette(c: Catppuccin): ThemePalette {
  return makePalette({
    isDark: c.isDark, base: c.base, mantle: c.mantle, crust: c.crust, surface: c.surface0,
    overlay0: c.overlay0, overlay1: c.overlay1, overlay2: c.overlay2, text: c.text, secondary: c.subtext0,
    accent: c.mauve, green: c.green, red: c.red, yellow: c.yellow, blue: c.blue, teal: c.teal, orange: c.peach,
    // VS Code: button/badge text Crust. Zed: selected rows at 40% over the sidebar, with Text.
    activeBorder: c.lavender, onAccent: c.crust,
    listSelection: composite(c.rowSelection, 0.4, c.mantle), listSelectionText: c.text,
    cursor: c.rosewater, cursorText: c.isDark ? c.crust : c.base,
    // VS Code: editor selection Overlay2 at 30% in Latte, 25% otherwise; terminal selection Surface2.
    selectionBackground: c.overlay2, selectionOpacity: c.isDark ? 0.25 : 0.3, terminalSelectionBackground: c.surface2,
    // VS Code: line highlight Text 7%, diff lines Green/Red 15%, find matches Red / Sky.
    lineHighlight: c.text, lineHighlightOpacity: 0.07, diffLineOpacity: 0.15, findCurrent: c.red, findOther: c.sky,
    // Extended colors 16/17 are Peach and Rosewater.
    ansi: [...c.ansi, c.peach, c.rosewater],
  });
}

function catppuccinSyntax(c: Catppuccin): ThemeSyntaxPalette {
  // VS Code: operators Teal, functions and comments italic (italicComments defaults on).
  return makeSyntax({
    keyword: c.mauve, string: c.green, escape: c.pink, comment: c.overlay2, number: c.peach,
    function: c.blue, key: c.blue, punctuation: c.overlay2, operatorColor: c.teal, builtin: c.red,
    hunk: c.peach, diffFile: c.blue, diffPath: c.pink, italic: ["comment", "function"],
  });
}

const latte: Catppuccin = {
  isDark: false,
  rosewater: "dc8a78", pink: "ea76cb", mauve: "8839ef", red: "d20f39", peach: "fe640b", yellow: "df8e1d",
  green: "40a02b", teal: "179299", sky: "04a5e5", blue: "1e66f5", lavender: "7287fd",
  text: "4c4f69", subtext0: "6c6f85", overlay2: "7c7f93", overlay1: "8c8fa1", overlay0: "9ca0b0",
  surface2: "acb0be", surface0: "ccd0da", base: "eff1f5", mantle: "e6e9ef", crust: "dce0e8",
  ansi: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be",
         "6c6f85", "de293e", "49af3d", "eea02d", "456eff", "fe85d8", "2d9fa8", "bcc0cc"],
  rowSelection: "8f94a7",
};
const frappe: Catppuccin = {
  isDark: true,
  rosewater: "f2d5cf", pink: "f4b8e4", mauve: "ca9ee6", red: "e78284", peach: "ef9f76", yellow: "e5c890",
  green: "a6d189", teal: "81c8be", sky: "99d1db", blue: "8caaee", lavender: "babbf1",
  text: "c6d0f5", subtext0: "a5adce", overlay2: "949cbb", overlay1: "838ba7", overlay0: "737994",
  surface2: "626880", surface0: "414559", base: "303446", mantle: "292c3c", crust: "232634",
  ansi: ["51576d", "e78284", "a6d189", "e5c890", "8caaee", "f4b8e4", "81c8be", "a5adce",
         "626880", "e67172", "8ec772", "d9ba73", "7b9ef0", "f2a4db", "5abfb5", "b5bfe2"],
  rowSelection: "7c829a",
};
const macchiato: Catppuccin = {
  isDark: true,
  rosewater: "f4dbd6", pink: "f5bde6", mauve: "c6a0f6", red: "ed8796", peach: "f5a97f", yellow: "eed49f",
  green: "a6da95", teal: "8bd5ca", sky: "91d7e3", blue: "8aadf4", lavender: "b7bdf8",
  text: "cad3f5", subtext0: "a5adcb", overlay2: "939ab7", overlay1: "8087a2", overlay0: "6e738d",
  surface2: "5b6078", surface0: "363a4f", base: "24273a", mantle: "1e2030", crust: "181926",
  ansi: ["494d64", "ed8796", "a6da95", "eed49f", "8aadf4", "f5bde6", "8bd5ca", "a5adcb",
         "5b6078", "ec7486", "8ccf7f", "e1c682", "78a1f6", "f2a9dd", "63cbc0", "b8c0e0"],
  rowSelection: "737995",
};
const mocha: Catppuccin = {
  isDark: true,
  rosewater: "f5e0dc", pink: "f5c2e7", mauve: "cba6f7", red: "f38ba8", peach: "fab387", yellow: "f9e2af",
  green: "a6e3a1", teal: "94e2d5", sky: "89dceb", blue: "89b4fa", lavender: "b4befe",
  text: "cdd6f4", subtext0: "a6adc8", overlay2: "9399b2", overlay1: "7f849c", overlay0: "6c7086",
  surface2: "585b70", surface0: "313244", base: "1e1e2e", mantle: "181825", crust: "11111b",
  ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
         "585b70", "f37799", "89d88b", "ebd391", "74a8fc", "f2aede", "6bd7ca", "bac2de"],
  rowSelection: "6f728d",
};

/**
 * Dracula Classic. Where the spec's prose differs from the official editor ports, the ports win:
 * numbers/booleans are Purple and escapes Pink, and list selection is Selection with Foreground text.
 */
const draculaPalette = makePalette({
  isDark: true, base: "282a36", mantle: "21222c", crust: "191a21", surface: "343746",
  overlay0: "6272a4", overlay1: "6272a4", overlay2: "6272a4", text: "f8f8f2", secondary: "a9abb6",
  accent: "bd93f9", green: "50fa7b", red: "ff5555", yellow: "f1fa8c", blue: "8be9fd", teal: "8be9fd", orange: "ffb86c",
  listSelection: "44475a", listSelectionText: "f8f8f2", cursor: "f8f8f2", selectionBackground: "44475a", lineHighlight: "6272a4", lineHighlightOpacity: 0.25,
  ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
         "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff", "ffb86c", "f8f8f2"],
});
const draculaSyntax = makeSyntax({
  keyword: "ff79c6", string: "f1fa8c", escape: "ff79c6", comment: "6272a4",
  number: "bd93f9", function: "50fa7b", key: "8be9fd", punctuation: "f8f8f2", operatorColor: "ff79c6",
  builtin: "bd93f9", hunk: "6272a4", diffFile: "6272a4", diffPath: "6272a4", italic: ["comment", "builtin"],
});

/** GitHub Light/Dark Default, from Primer primitives via the github-nvim-theme port. */
const githubLight = makePalette({
  isDark: false, base: "ffffff", mantle: "f6f8fa", surface: "eaeef2",
  overlay0: "d0d7de", overlay1: "6e7781", overlay2: "57606a", text: "1f2328", secondary: "656d76",
  accent: "0969da", green: "1a7f37", red: "d1242f", yellow: "9a6700", blue: "0969da", teal: "1b7c83", orange: "bc4c00",
  listSelection: composite("afb8c1", 0.2, "f6f8fa"), listSelectionText: "1f2328",
  cursor: "0969da", selectionBackground: "0969da", selectionOpacity: 0.15,
  lineHighlight: "eaeef2", lineHighlightOpacity: 0.5,
  ansi: ["24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781",
         "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"],
});
const githubLightSyntax = makeSyntax({
  keyword: "cf222e", string: "0a3069", escape: "116329", comment: "57606a",
  number: "0550ae", function: "6639ba", key: "0550ae", punctuation: "1f2328", operatorColor: "0550ae",
  builtin: "0550ae", hunk: "8250df",
});
const githubDark = makePalette({
  isDark: true, base: "0d1117", mantle: "010409", surface: "21262d",
  overlay0: "30363d", overlay1: "6e7681", overlay2: "8b949e", text: "e6edf3", secondary: "848d97",
  accent: "2f81f7", green: "3fb950", red: "f85149", yellow: "d29922", blue: "58a6ff", teal: "39c5cf", orange: "db6d28",
  listSelection: composite("6e7681", 0.4, "010409"), listSelectionText: "e6edf3",
  cursor: "2f81f7", selectionBackground: "2f81f7", selectionOpacity: 0.3,
  lineHighlight: "6e7681", lineHighlightOpacity: 0.1,
  ansi: ["484f58", "ff7b72", "3fb950", "d29922", "58a6ff", "bc8cff", "39c5cf", "b1bac4",
         "6e7681", "ffa198", "56d364", "e3b341", "79c0ff", "d2a8ff", "56d4dd", "ffffff"],
});
const githubDarkSyntax = makeSyntax({
  keyword: "ff7b72", string: "a5d6ff", escape: "7ee787", comment: "8b949e",
  number: "79c0ff", function: "d2a8ff", key: "79c0ff", punctuation: "e6edf3", operatorColor: "79c0ff",
  builtin: "79c0ff", hunk: "d2a8ff",
});

/** Gruvbox. Dark uses the bright accents and light the faded ones, as upstream does. */
const gruvboxLight = makePalette({
  isDark: false, base: "fbf1c7", mantle: "f2e5bc", crust: "ebdbb2", surface: "ebdbb2",
  overlay0: "d5c4a1", overlay1: "928374", overlay2: "7c6f64", text: "3c3836", secondary: "665c54",
  accent: "af3a03", green: "79740e", red: "9d0006", yellow: "b57614", blue: "076678", teal: "427b58", orange: "af3a03",
  listSelection: "c8b899", listSelectionText: "3c3836",
  cursor: "3c3836", selectionBackground: "bdae93",
  ansi: ["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
         "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"],
});
const gruvboxLightSyntax = makeSyntax({
  keyword: "9d0006", string: "79740e", escape: "af3a03", comment: "928374",
  number: "8f3f71", function: "79740e", key: "076678", punctuation: "3c3836", operatorColor: "3c3836",
  builtin: "af3a03", italic: ["comment"],
});
const gruvboxDark = makePalette({
  isDark: true, base: "282828", mantle: "1d2021", surface: "3c3836",
  overlay0: "504945", overlay1: "928374", overlay2: "a89984", text: "ebdbb2", secondary: "bdae93",
  accent: "fe8019", green: "b8bb26", red: "fb4934", yellow: "fabd2f", blue: "83a598", teal: "8ec07c", orange: "fe8019",
  listSelection: "5b524c", listSelectionText: "ebdbb2",
  cursor: "ebdbb2", selectionBackground: "665c54",
  ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
         "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"],
});
const gruvboxDarkSyntax = makeSyntax({
  keyword: "fb4934", string: "b8bb26", escape: "fe8019", comment: "928374",
  number: "d3869b", function: "b8bb26", key: "83a598", punctuation: "ebdbb2", operatorColor: "ebdbb2",
  builtin: "fe8019", italic: ["comment"],
});

/** Nord. Row selection keeps the accent fill, as nordtheme/visual-studio-code does. */
const nordPalette = makePalette({
  isDark: true, base: "2e3440", mantle: "3b4252", surface: "434c5e",
  overlay0: "4c566a", overlay1: "616e88", overlay2: "616e88", text: "d8dee9", secondary: "a5abb6",
  accent: "88c0d0", green: "a3be8c", red: "bf616a", yellow: "ebcb8b", blue: "81a1c1", teal: "8fbcbb", orange: "d08770",
  cursor: "d8dee9", selectionBackground: "434c5e", terminalSelectionBackground: "4c566a",
  ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
         "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"],
});
const nordSyntax = makeSyntax({
  keyword: "81a1c1", string: "a3be8c", escape: "ebcb8b", comment: "616e88",
  number: "b48ead", function: "88c0d0", key: "8fbcbb", punctuation: "eceff4", operatorColor: "81a1c1",
  builtin: "81a1c1",
});

/** Atom One Light/Dark. One Light has no official terminal port; its ANSI reuses the same hue roles. */
const oneLight = makePalette({
  isDark: false, base: "fafafa", mantle: "eaeaeb", crust: "dbdbdc", surface: "dbdbdc",
  overlay0: "9d9d9f", overlay1: "9d9d9f", overlay2: "a0a1a7", text: "383a42", secondary: "696c77",
  accent: "526fff", green: "50a14f", red: "e45649", yellow: "cb7701", blue: "4078f2", teal: "0184bc", orange: "b76b01",
  listSelection: "cacaca", listSelectionText: "383a42", cursor: "526fff", selectionBackground: "e5e5e6", lineHighlight: "383a42", lineHighlightOpacity: 0.05,
  ansi: ["383a42", "e45649", "50a14f", "cb7701", "4078f2", "a626a4", "0184bc", "a0a1a7",
         "696c77", "ca1243", "50a14f", "b76b01", "4078f2", "a626a4", "0184bc", "dbdbdc"],
});
const oneLightSyntax = makeSyntax({
  keyword: "a626a4", string: "50a14f", escape: "0184bc", comment: "a0a1a7",
  number: "b76b01", function: "4078f2", key: "e45649", punctuation: "383a42", operatorColor: "0184bc",
  builtin: "e45649", italic: ["comment"],
});
const oneDark = makePalette({
  isDark: true, base: "282c34", mantle: "21252b", crust: "181a1f", surface: "353b45",
  overlay0: "3e4451", overlay1: "636d83", overlay2: "5c6370", text: "abb2bf", secondary: "828997",
  accent: "528bff", green: "98c379", red: "e06c75", yellow: "e5c07b", blue: "61afef", teal: "56b6c2", orange: "d19a66",
  listSelection: "454a56", listSelectionText: "d7dae0", cursor: "528bff", selectionBackground: "3e4451", lineHighlight: "99bbff", lineHighlightOpacity: 0.04,
  ansi: ["282c34", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
         "3e4452", "be5046", "98c379", "d19a66", "61afef", "c678dd", "56b6c2", "5c6370"],
});
const oneDarkSyntax = makeSyntax({
  keyword: "c678dd", string: "98c379", escape: "56b6c2", comment: "5c6370",
  number: "d19a66", function: "61afef", key: "e06c75", punctuation: "abb2bf", operatorColor: "56b6c2",
  builtin: "e06c75", italic: ["comment"],
});

/** Rosé Pine and Dawn. Dawn uses Pine rather than Iris as the accent: Iris under Base text is low-contrast. */
const rosePine = makePalette({
  isDark: true, base: "191724", mantle: "1f1d2e", surface: "26233a",
  overlay0: "403d52", overlay1: "6e6a86", overlay2: "908caa", text: "e0def4", secondary: "908caa",
  accent: "c4a7e7", green: "9ccfd8", red: "eb6f92", yellow: "f6c177", blue: "c4a7e7", teal: "31748f", orange: "ebbcba",
  listSelection: "524f67", listSelectionText: "e0def4",
  cursor: "e0def4", selectionBackground: "c4a7e7", selectionOpacity: 0.15, terminalSelectionBackground: "403d52",
  ansi: ["26233a", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
         "6e6a86", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4"],
});
const rosePineSyntax = makeSyntax({
  keyword: "31748f", string: "f6c177", escape: "31748f", comment: "908caa",
  number: "f6c177", function: "ebbcba", key: "9ccfd8", punctuation: "908caa", operatorColor: "908caa",
  builtin: "eb6f92", hunk: "c4a7e7", diffFile: "9ccfd8", diffPath: "ebbcba", italic: ["comment", "builtin", "key"],
});
const rosePineDawn = makePalette({
  isDark: false, base: "faf4ed", mantle: "fffaf3", surface: "f2e9e1",
  overlay0: "dfdad9", overlay1: "9893a5", overlay2: "797593", text: "464261", secondary: "797593",
  accent: "286983", green: "56949f", red: "b4637a", yellow: "ea9d34", blue: "907aa9", teal: "286983", orange: "d7827e",
  listSelection: "cecacd", listSelectionText: "464261",
  cursor: "464261", selectionBackground: "907aa9", selectionOpacity: 0.15, terminalSelectionBackground: "dfdad9",
  ansi: ["f2e9e1", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261",
         "9893a5", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261"],
});
const rosePineDawnSyntax = makeSyntax({
  keyword: "286983", string: "ea9d34", escape: "286983", comment: "797593",
  number: "ea9d34", function: "d7827e", key: "56949f", punctuation: "797593", operatorColor: "797593",
  builtin: "b4637a", hunk: "907aa9", diffFile: "56949f", diffPath: "d7827e", italic: ["comment", "builtin", "key"],
});

/** Solarized. The official 16-color mapping is shared by both modes (bright black is Base03). */
const solarizedAnsi = ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                       "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"];
const solarizedLight = makePalette({
  isDark: false, base: "fdf6e3", mantle: "eee8d5", surface: "eee8d5",
  overlay0: "93a1a1", overlay1: "93a1a1", overlay2: "839496", text: "657b83", secondary: "839496",
  accent: "268bd2", green: "859900", red: "dc322f", yellow: "b58900", blue: "268bd2", teal: "2aa198", orange: "cb4b16",
  listSelection: "dfca88", listSelectionText: "073642",
  cursor: "657b83", selectionBackground: "eee8d5", ansi: solarizedAnsi,
});
const solarizedLightSyntax = makeSyntax({
  keyword: "859900", string: "2aa198", escape: "dc322f", comment: "93a1a1",
  number: "2aa198", function: "268bd2", key: "268bd2", punctuation: "657b83", operatorColor: "859900",
  builtin: "859900", italic: ["comment"],
});
const solarizedDark = makePalette({
  isDark: true, base: "002b36", mantle: "073642", surface: "073642",
  overlay0: "586e75", overlay1: "586e75", overlay2: "657b83", text: "839496", secondary: "657b83",
  accent: "268bd2", green: "859900", red: "dc322f", yellow: "b58900", blue: "268bd2", teal: "2aa198", orange: "cb4b16",
  listSelection: "005a6f", listSelectionText: "eee8d5",
  cursor: "839496", selectionBackground: "073642", ansi: solarizedAnsi,
});
const solarizedDarkSyntax = makeSyntax({
  keyword: "859900", string: "2aa198", escape: "dc322f", comment: "586e75",
  number: "2aa198", function: "268bd2", key: "268bd2", punctuation: "839496", operatorColor: "859900",
  builtin: "859900", italic: ["comment"],
});

/** Tokyo Night (Night) and Day. Row selection is bg_visual, as LazyVim's snacks picker uses it. */
const tokyoNightDay = makePalette({
  isDark: false, base: "e1e2e7", mantle: "d0d5e3", crust: "c1c9df", surface: "c4c8da",
  overlay0: "a8aecb", overlay1: "68709a", overlay2: "848cb5", text: "3760bf", secondary: "6172b0",
  accent: "2e7de9", green: "587539", red: "f52a65", yellow: "8c6c3e", blue: "2e7de9", teal: "118c74", orange: "b15c00",
  activeBorder: "4094a3", listSelection: "b7c1e3", listSelectionText: "3760bf", cursor: "3760bf", selectionBackground: "b7c1e3",
  ansi: ["b4b5b9", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "6172b0",
         "a1a6c5", "ff4774", "5c8524", "a27629", "358aff", "a463ff", "007ea8", "3760bf"],
});
const tokyoNightDaySyntax = makeSyntax({
  keyword: "9854f1", string: "587539", escape: "9854f1", comment: "848cb5",
  number: "b15c00", function: "2e7de9", key: "387068", punctuation: "6172b0", operatorColor: "006a83",
  builtin: "f52a65", italic: ["comment"],
});
const tokyoNight = makePalette({
  isDark: true, base: "1a1b26", mantle: "16161e", crust: "0c0e14", surface: "292e42",
  overlay0: "3b4261", overlay1: "737aa2", overlay2: "565f89", text: "c0caf5", secondary: "a9b1d6",
  accent: "7aa2f7", green: "9ece6a", red: "f7768e", yellow: "e0af68", blue: "7aa2f7", teal: "1abc9c", orange: "ff9e64",
  activeBorder: "27a1b9", listSelection: "283457", listSelectionText: "c0caf5", cursor: "c0caf5", selectionBackground: "283457",
  ansi: ["15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
         "414868", "ff899d", "9fe044", "faba4a", "8db0ff", "c7a9ff", "a4daff", "c0caf5"],
});
const tokyoNightSyntax = makeSyntax({
  keyword: "bb9af7", string: "9ece6a", escape: "bb9af7", comment: "565f89",
  number: "ff9e64", function: "7aa2f7", key: "73daca", punctuation: "a9b1d6", operatorColor: "89ddff",
  builtin: "f7768e", italic: ["comment"],
});

const PALETTES: Record<Exclude<AppTheme, "system">, [ThemePalette, ThemeSyntaxPalette]> = {
  latte: [catppuccinPalette(latte), catppuccinSyntax(latte)],
  frappe: [catppuccinPalette(frappe), catppuccinSyntax(frappe)],
  macchiato: [catppuccinPalette(macchiato), catppuccinSyntax(macchiato)],
  mocha: [catppuccinPalette(mocha), catppuccinSyntax(mocha)],
  dracula: [draculaPalette, draculaSyntax],
  githubLight: [githubLight, githubLightSyntax],
  githubDark: [githubDark, githubDarkSyntax],
  gruvboxLight: [gruvboxLight, gruvboxLightSyntax],
  gruvboxDark: [gruvboxDark, gruvboxDarkSyntax],
  nord: [nordPalette, nordSyntax],
  oneLight: [oneLight, oneLightSyntax],
  oneDark: [oneDark, oneDarkSyntax],
  rosePineDawn: [rosePineDawn, rosePineDawnSyntax],
  rosePine: [rosePine, rosePineSyntax],
  solarizedLight: [solarizedLight, solarizedLightSyntax],
  solarizedDark: [solarizedDark, solarizedDarkSyntax],
  tokyoNightDay: [tokyoNightDay, tokyoNightDaySyntax],
  tokyoNight: [tokyoNight, tokyoNightSyntax],
};

/** Undefined for System, which follows the Mac's appearance. */
export function themePalette(theme: AppTheme): ThemePalette | undefined {
  return theme === "system" ? undefined : PALETTES[theme][0];
}

export function themeSyntax(theme: AppTheme): ThemeSyntaxPalette | undefined {
  return theme === "system" ? undefined : PALETTES[theme][1];
}

export function themeIsDark(theme: AppTheme): boolean | undefined {
  return themePalette(theme)?.isDark;
}
