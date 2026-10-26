import { contextBridge, ipcRenderer, type IpcRendererEvent } from "electron";
import { EVENT_CHANNELS, SERVICE_ACTIONS } from "../shared/channels";

const services = SERVICE_ACTIONS as Record<string, readonly string[]>;
const events = new Set<string>(EVENT_CHANNELS);

contextBridge.exposeInMainWorld("octo", {
  call(service: string, action: string, ...args: unknown[]) {
    if (!services[service]?.includes(action)) return Promise.reject(new Error(`Unknown action ${service}.${action}`));
    return ipcRenderer.invoke(`call:${service}`, action, ...args);
  },
  on(channel: string, listener: (payload: unknown) => void) {
    if (!events.has(channel)) throw new Error(`Unknown event ${channel}`);
    const handler = (_event: IpcRendererEvent, payload: unknown) => listener(payload);
    ipcRenderer.on(channel, handler);
    return () => { ipcRenderer.removeListener(channel, handler); };
  },
  platform: process.platform,
});
