import { BrowserWindow, ipcMain, type IpcMainInvokeEvent, type WebContents } from "electron";
import { SERVICE_ACTIONS } from "../shared/channels";
import type { EventName, Events, ServiceName } from "../shared/ipc";

const trusted = new Set<number>();
export function trustWebContents(contents: WebContents): void {
  trusted.add(contents.id);
  contents.once("destroyed", () => trusted.delete(contents.id));
}

function isTrustedSender(event: IpcMainInvokeEvent): boolean {
  return trusted.has(event.sender.id) && event.senderFrame === event.sender.mainFrame;
}

/** Errors cross IPC as plain messages; stacks stay in the main process. */
function rethrow(error: unknown): never {
  throw new Error(error instanceof Error ? error.message : String(error));
}

/** Exposes a service's allowlisted actions. Each action is bound to the service object. */
export function registerService(name: ServiceName, implementation: object): void {
  const allowed = new Set<string>(SERVICE_ACTIONS[name]);
  ipcMain.handle(`call:${name}`, async (event, action: string, ...args: unknown[]) => {
    if (!isTrustedSender(event)) throw new Error("Untrusted sender");
    if (!allowed.has(action)) throw new Error(`Unknown action ${name}.${action}`);
    const method = (implementation as Record<string, unknown>)[action];
    if (typeof method !== "function") throw new Error(`Unavailable action ${name}.${action}`);
    try { return await (method as (...a: unknown[]) => unknown).apply(implementation, args); } catch (error) { rethrow(error); }
  });
}

export function broadcast<K extends EventName>(channel: K, payload: Events[K]): void {
  for (const window of BrowserWindow.getAllWindows()) {
    if (trusted.has(window.webContents.id) && !window.webContents.isDestroyed()) window.webContents.send(channel, payload);
  }
}

export function send<K extends EventName>(target: WebContents, channel: K, payload: Events[K]): void {
  if (!target.isDestroyed()) target.send(channel, payload);
}
