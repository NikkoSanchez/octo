import { describe, expect, it } from "vitest";
import { APP_THEMES, composite } from "@octo/core";
import { CONTROL_BORDER_CONTRAST, contrastRatio, resolveTheme, themeVariables } from "./theme";

/** An `rgba()` variable flattened onto an opaque surface. */
function flatten(rgba: string, surface: string): string {
  const [r, g, b, alpha] = rgba.match(/[\d.]+/g)!.map(Number) as [number, number, number, number];
  return composite(((r << 16) | (g << 8) | b).toString(16).padStart(6, "0"), alpha, surface);
}

describe("control border", () => {
  it("outlines fields at the same contrast in every theme, and never darker than a dark panel", () => {
    for (const theme of APP_THEMES) for (const dark of [false, true]) {
      const resolved = resolveTheme(theme, { dark });
      const panel = resolved.palette.mantle;
      const line = flatten(themeVariables(resolved)["--control-border"]!, panel);
      expect(contrastRatio(line, panel), theme).toBeGreaterThanOrEqual(CONTROL_BORDER_CONTRAST);
      if (resolved.palette.isDark) expect(contrastRatio(line, "000000"), theme).toBeGreaterThan(contrastRatio(panel, "000000"));
    }
  });
});
