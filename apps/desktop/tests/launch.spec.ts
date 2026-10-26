import { expect, test } from "@playwright/test";
import { launchApp } from "./fixtures";

test("launches a sandboxed window with Octo's chrome", async () => {
  const { app, page, dataDirectory, close } = await launchApp();
  try {
    await expect(page.getByTestId("sidebar")).toBeVisible();
    const info = await page.evaluate(() => window.octo.call("app", "info"));
    expect(info.channel).toBe(process.env.OCTO_PACKAGED_CHANNEL ?? "dev");
    expect(info.dataDirectory).toBe(dataDirectory);
    // The renderer has no Node access.
    expect(await page.evaluate(() => typeof (globalThis as { require?: unknown }).require)).toBe("undefined");
    const chrome = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows()[0];
      const prefs = (window.webContents as unknown as { getLastWebPreferences(): { sandbox?: boolean; contextIsolation?: boolean } | null }).getLastWebPreferences();
      return { min: window.getMinimumSize(), sandbox: prefs?.sandbox, isolation: prefs?.contextIsolation, buttons: window.getWindowButtonPosition?.() };
    });
    expect(chrome.min).toEqual([480, 600]);
    expect(chrome.sandbox).toBe(true);
    expect(chrome.isolation).toBe(true);
    if (process.platform === "darwin") expect(chrome.buttons).toEqual({ x: 20, y: 17 });
  } finally {
    await close();
  }
});
