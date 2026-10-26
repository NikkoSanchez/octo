import { app, Menu, shell, type MenuItemConstructorOptions } from "electron";
import { MENU_GROUPS, type MenuCommand } from "../shared/menu";

/**
 * The menu bar mirrors the renderer's command list. Accelerators are displayed but not registered:
 * the renderer routes keys itself, so a terminal's own bindings keep precedence where they should.
 */
export function buildMenu(commands: MenuCommand[], run: (id: string) => void, development: boolean): Menu {
  const byID = new Map(commands.map((c) => [c.id, c]));
  const item = (id: string, fallback: string): MenuItemConstructorOptions => {
    const command = byID.get(id);
    return {
      label: command?.title ?? fallback, enabled: command?.enabled ?? false, click: () => run(id),
      ...(command?.accelerator ? { accelerator: command.accelerator, registerAccelerator: false } : {}),
    };
  };
  const workspace: MenuItemConstructorOptions[] = [];
  for (const group of MENU_GROUPS) {
    const items = commands.filter((c) => c.group === group);
    if (items.length === 0) continue;
    if (workspace.length) workspace.push({ type: "separator" });
    workspace.push({ label: group, enabled: false });
    for (const command of items) workspace.push(item(command.id, command.title));
  }
  const template: MenuItemConstructorOptions[] = [
    ...(process.platform === "darwin" ? [{
      label: app.getName(),
      submenu: [
        { role: "about" }, { type: "separator" }, item("settings", "Settings…"), { type: "separator" },
        { role: "services" }, { type: "separator" }, { role: "hide" }, { role: "hideOthers" }, { role: "unhide" },
        { type: "separator" }, { role: "quit" },
      ] as MenuItemConstructorOptions[],
    }] : []),
    {
      label: "File",
      submenu: [
        item("newThread", "New Thread"), item("newChat", "New Chat Without a Project"), item("addProject", "Add Project…"),
        { type: "separator" }, { role: "close" },
      ],
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        ...(development ? [{ role: "reload" }, { role: "toggleDevTools" }, { type: "separator" }] as MenuItemConstructorOptions[] : []),
        { role: "togglefullscreen" },
      ],
    },
    { label: "Workspace", submenu: workspace.length ? workspace : [{ label: "No Commands", enabled: false }] },
    { role: "windowMenu" },
    { role: "help", submenu: [{ label: "Octo on GitHub", click: () => void shell.openExternal("https://github.com/NikkoSanchez/octo") }] },
  ];
  return Menu.buildFromTemplate(template);
}
