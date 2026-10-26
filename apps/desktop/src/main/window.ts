import { BrowserWindow, shell } from "electron";
import { join } from "node:path";
import { trustWebContents } from "./ipc";

/** The close button's top-left corner. */
export const TRAFFIC_LIGHTS = { x: 20, y: 17 };

export function createMainWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 1380,
    height: 880,
    minWidth: 480,
    minHeight: 600,
    show: false,
    title: "Octo",
    backgroundColor: "#00000000",
    ...(process.platform === "darwin"
      ? { titleBarStyle: "hiddenInset" as const, trafficLightPosition: TRAFFIC_LIGHTS, vibrancy: "sidebar" as const, visualEffectState: "followWindow" as const }
      : {}),
    webPreferences: {
      preload: join(__dirname, "../preload/index.cjs"),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webviewTag: false,
      spellcheck: true,
    },
  });
  trustWebContents(window.webContents);
  window.once("ready-to-show", () => window.show());
  // The app window never navigates or opens windows itself; links go to the default browser.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^(https?|mailto):/.test(url)) void shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    if (url !== window.webContents.getURL()) event.preventDefault();
  });
  if (process.env.ELECTRON_RENDERER_URL) void window.loadURL(process.env.ELECTRON_RENDERER_URL);
  else void window.loadFile(join(__dirname, "../renderer/index.html"));
  return window;
}
