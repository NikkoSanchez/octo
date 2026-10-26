import { _electron as electron, type ElectronApplication, type Page } from "@playwright/test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Launches the built app against a throwaway data folder, so smoke tests never read or write the
 * installed app's chats.
 */
export async function launchApp(extraEnv: Record<string, string> = {}, configure?: (directory: string) => void): Promise<{ app: ElectronApplication; page: Page; dataDirectory: string; close: () => Promise<void> }> {
  const dataDirectory = mkdtempSync(join(tmpdir(), "octo-smoke-"));
  configure?.(dataDirectory);
  const app = await electron.launch({
    ...(process.env.OCTO_PACKAGED_APP ? { executablePath: process.env.OCTO_PACKAGED_APP, args: [] } : { args: [join(import.meta.dirname, "../out/main/index.js")] }),
    env: { ...process.env, OCTO_USER_DATA: dataDirectory, ...extraEnv },
  });
  const page = await app.firstWindow();
  return {
    app, page, dataDirectory,
    close: async () => { await app.close(); rmSync(dataDirectory, { recursive: true, force: true }); },
  };
}

/**
 * Answers the next native popup or context menu by choosing the item with this label, as a user
 * would. Native menus are outside the page, so Playwright can't click them directly.
 */
export async function chooseMenuItem(app: ElectronApplication, label: string): Promise<void> {
  await app.evaluate(({ Menu }, label) => {
    const original = Menu.prototype.popup;
    Menu.prototype.popup = function (this: Electron.Menu, options?: Electron.PopupOptions) {
      Menu.prototype.popup = original;
      const find = (menu: Electron.Menu): Electron.MenuItem | undefined => {
        for (const item of menu.items) {
          if (item.label === label) return item;
          const nested = item.submenu && find(item.submenu);
          if (nested) return nested;
        }
      };
      const item = find(this);
      if (!item) throw new Error(`No menu item labelled ${label}`);
      item.click();
      options?.callback?.();
    };
  }, label);
}
