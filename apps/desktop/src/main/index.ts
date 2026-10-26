import { app, BrowserWindow, dialog, Menu, nativeTheme, session } from "electron";
import { spawn as spawnPty } from "node-pty";
import { join } from "node:path";
import { WorkspaceStore } from "@octo/core/node";
import { BrowserService } from "./browser/browserService";
import { applyIdentity } from "./identity";
import { broadcast, registerService } from "./ipc";
import { buildMenu } from "./menu";
import { electronPlatform } from "./platform";
import { AppService } from "./services/appService";
import { ReviewService } from "./services/reviewService";
import { AppStore } from "./store/appStore";
import { PreferencesFile } from "./store/preferences";
import { TerminalService, type PtyProcess } from "./terminal/terminalService";
import { createMainWindow } from "./window";
import { menuShortcutMatches, type MenuCommand } from "../shared/menu";
import type { StatePatch } from "../shared/state";

const { channel, dataDirectory } = applyIdentity();
const development = !app.isPackaged;

// One instance per data folder: two writers would corrupt the archive.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let mainWindow: BrowserWindow | undefined;
  const currentWindow = () => (mainWindow && !mainWindow.isDestroyed() ? mainWindow : undefined);

  // The archive lives in the pinned data folder unless a test points elsewhere explicitly.
  const workspacePath = process.env.OCTO_WORKSPACE_PATH ?? join(dataDirectory, "workspace.json");
  const storage = new WorkspaceStore(workspacePath, { isStandard: process.env.OCTO_WORKSPACE_PATH === undefined });
  const preferences = new PreferencesFile(dataDirectory);

  // Created below; the store's hooks only run after load.
  let terminal: TerminalService | undefined;
  let browser: BrowserService | undefined;
  const store = new AppStore({
    storage, preferences, platform: electronPlatform,
    ui: (event) => broadcast("ui:event", event),
    hooks: {
      terminalTabCount: (projectID) => terminal?.tabCount(projectID) ?? 0,
      closeBrowser: (id) => browser?.close(id),
      // The renderer recolors its terminals from the published theme.
      applyTerminalTheme: () => {},
    },
  });
  store.state.subscribe((version, patches) => broadcast("state:patches", { version, patches: patches as StatePatch[] }));

  terminal = new TerminalService({
    spawn: (file, args, options) => spawnPty(file, args, { name: "xterm-256color", ...options }) as unknown as PtyProcess,
    emit: (event) => broadcast("terminal:event", event),
    projectDirectory: (projectID) => store.archive.projects.find((p) => p.id === projectID)?.rootPath,
  });

  browser = new BrowserService({
    window: currentWindow,
    shortcut: (input, type) => {
      // Panel and terminal commands can share a key; the menu marks the one available now as enabled.
      const matching = menuCommands.filter((c) => menuShortcutMatches(c.accelerator, input, process.platform === "darwin"));
      const command = matching.find((c) => c.enabled) ?? matching[0];
      if (!command) return false;
      if (type === "keyDown" && command.enabled) { currentWindow()?.webContents.focus(); broadcast("ui:event", { type: "command", id: command.id }); }
      return true;
    },
    emit: (event) => broadcast("browser:event", event),
    tab: (projectID, id) => {
      const tabs = store.archive.projects.find((p) => p.id === projectID)?.panelTabs;
      if (!tabs?.tabs.some((t) => t.kind === "browser" && t.id === id)) return undefined;
      return { address: tabs.browserAddresses[id], isPrivate: tabs.privateBrowsers.includes(id) };
    },
    recordAddress: (projectID, id, address) => store.updatePanelTabsAction(projectID, { type: "recordAddress", id, address }),
    openTab: (projectID, id, isPrivate) => store.updatePanelTabsAction(projectID, { type: "openBrowser", id, isPrivate }),
    closeTab: (projectID, id) => store.updatePanelTabsAction(projectID, { type: "close", tab: { kind: "browser", id } }),
    attachAnnotation: (annotation, screenshot, projectID) => void store.attachBrowserAnnotation(annotation, screenshot, projectID),
    attachScreenshot: (data, projectID) => void store.attachBrowserScreenshot(data, projectID),
  });

  const review = new ReviewService((event) => broadcast("review:event", event), (model, changes) => store.generateCommitMessage(model, changes));

  let menuCommands: MenuCommand[] = [];
  const applyMenu = () => Menu.setApplicationMenu(buildMenu(menuCommands, (id) => broadcast("ui:event", { type: "command", id }), development));

  const terminals = terminal;
  const appService = new AppService(store, { channel, dataDirectory }, {
    openCheckoutInEditor: (projectID, directory) => {
      try { terminals.openDirectoryInEditor(projectID, directory); broadcast("ui:event", { type: "showTerminal" }); }
      catch (error) { store.state.update((d) => { d.error = (error as Error).message; }); }
    },
    openFileInEditor: async (projectID, directory, path, line) => {
      try { await terminals.openInEditor(projectID, directory, path, line); broadcast("ui:event", { type: "showTerminal" }); }
      catch (error) { store.state.update((d) => { d.error = (error as Error).message; }); }
    },
    setMenu: (commands) => { menuCommands = commands; applyMenu(); },
  });

  registerService("app", appService);
  registerService("store", store);
  registerService("review", review);
  registerService("terminal", terminal);
  registerService("browser", browser);

  app.on("second-instance", () => {
    const window = currentWindow();
    if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); }
  });

  const pages = browser;
  const openWindow = () => {
    const window = createMainWindow();
    mainWindow = window;
    pages.attachAll(window);
    window.on("close", (event) => { if (process.platform === "darwin" && !quitting) { event.preventDefault(); window.hide(); } });
    window.on("closed", () => { pages.hideAll(); if (mainWindow === window) mainWindow = undefined; });
  };

  app.whenReady().then(async () => {
    // The app's own content asks for nothing; browser tabs get their own sessions and handlers.
    session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    nativeTheme.on("updated", () => store.setSystemDark(nativeTheme.shouldUseDarkColors));
    applyMenu();
    await store.load();
    openWindow();
    app.on("activate", () => { const window = currentWindow(); if (window) { window.show(); window.focus(); } else openWindow(); });
  });

  // Agents, terminals and pages end with the app; the archive and preferences are flushed first.
  let quitting = false, preparingQuit = false;
  app.on("before-quit", (event) => {
    if (quitting) return;
    event.preventDefault();
    if (preparingQuit) return;
    preparingQuit = true;
    void (async () => {
      const failures = await review.flushDrafts();
      if (failures.length) {
        const choice = await dialog.showMessageBox({ type: "warning", message: "Some file edits could not be saved.", detail: failures.join("\n\n"), buttons: ["Keep editing", "Quit without saving these edits"], cancelId: 0, defaultId: 0, noLink: true });
        if (choice.response === 0) { preparingQuit = false; return; }
      }
      quitting = true;
      review.dispose(); pages.shutdown(); terminals.shutdown();
      await store.shutdown().finally(() => app.quit());
    })().catch(() => { preparingQuit = false; });
  });

  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });
}
