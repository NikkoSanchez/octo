import type { CallArgs, CallResult, EventName, Events, ServiceName, Services } from "../../shared/ipc";
import { useUI } from "./state/ui";

/** Calls a main-process action. Errors arrive as plain messages. */
export function call<S extends ServiceName, A extends keyof Services[S] & string>(service: S, action: A, ...args: CallArgs<S, A>): Promise<CallResult<S, A>> {
  return window.octo.call(service, action, ...args).catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(message.replace(/^Error invoking remote method '[^']+': (?:Error: )?/, ""));
  });
}

/** Calls an action for its effect and shows any failure in the app's alert. */
export function run<S extends ServiceName, A extends keyof Services[S] & string>(service: S, action: A, ...args: CallArgs<S, A>): void {
  call(service, action, ...args).catch((error: unknown) => useUI.getState().showError(error instanceof Error ? error.message : String(error)));
}

export function on<K extends EventName>(channel: K, listener: (payload: Events[K]) => void): () => void {
  return window.octo.on(channel, listener);
}

export const isMac = window.octo.platform === "darwin";
