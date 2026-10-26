// Octo equivalents of T3 app-level helpers. Terminal implementation remains vendored.
export const isMacPlatform = (platform: string) => /Mac|iPhone|iPad|iPod/i.test(platform);
export const SELECTION_MULTI_CLICK_INTERVAL_MS = 500;
export function isMonospaceFamily(family: string): boolean {
  try {
    const context = document.createElement("canvas").getContext("2d"); if (!context) return true;
    for (const variant of ["normal 400", "normal 700", "italic 400", "italic 700"]) {
      context.font = `${variant} 32px ${family}, monospace`;
      const widths = ["i", "M", "W", "0", "@", "#", ".", " "].map((s) => context.measureText(s).width);
      if (widths.some((width) => Math.abs(width - widths[0]) > 0.01)) return false;
    }
    return true;
  } catch { return true; }
}

export const US_SHIFTED_TO_UNSHIFTED_KEYS: ReadonlyMap<string, string> = new Map([
  ["!", "1"],
  ["@", "2"],
  ["#", "3"],
  ["$", "4"],
  ["%", "5"],
  ["^", "6"],
  ["&", "7"],
  ["*", "8"],
  ["(", "9"],
  [")", "0"],
  ["~", "`"],
  ["_", "-"],
  ["+", "="],
  ["{", "["],
  ["}", "]"],
  ["|", "\\"],
  [":", ";"],
  ['"', "'"],
  ["<", ","],
  [">", "."],
  ["?", "/"],
]);
