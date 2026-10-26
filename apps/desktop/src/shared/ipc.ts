// The typed contract between the sandboxed renderer and the main process. The renderer calls
// allowlisted actions on named services and listens to allowlisted events; the preload rejects
// anything else, and main refuses requests that don't come from the app window's main frame.
import type { AppStore } from "../main/store/appStore";
import type { AppService } from "../main/services/appService";
import type { ReviewService } from "../main/services/reviewService";
import type { TerminalService } from "../main/terminal/terminalService";
import type { BrowserService } from "../main/browser/browserService";
import type { SERVICE_ACTIONS } from "./channels";
import type { StatePatches } from "./state";
import type { ReviewEvent } from "./review";
import type { TerminalEvent } from "./terminal";
import type { BrowserEvent } from "./browser";

type Actions<T, K extends readonly string[]> = { [A in K[number] & keyof T]: T[A] };

export interface Services {
  app: Actions<AppService, typeof SERVICE_ACTIONS.app>;
  store: Actions<AppStore, typeof SERVICE_ACTIONS.store>;
  review: Actions<ReviewService, typeof SERVICE_ACTIONS.review>;
  terminal: Actions<TerminalService, typeof SERVICE_ACTIONS.terminal>;
  browser: Actions<BrowserService, typeof SERVICE_ACTIONS.browser>;
}

export type ServiceName = keyof Services;

export type UIEvent = { type: "focusComposer" } | { type: "showTerminal" } | { type: "showThread" } | { type: "command"; id: string };

/** Main → renderer events. Events that belong to an owner carry it. */
export interface Events {
  "state:patches": StatePatches;
  "ui:event": UIEvent;
  "review:event": ReviewEvent;
  "terminal:event": TerminalEvent;
  "browser:event": BrowserEvent;
}

export type EventName = keyof Events;

type Method = (...args: never[]) => unknown;
export type CallArgs<S extends ServiceName, A extends keyof Services[S]> = Services[S][A] extends Method ? Parameters<Services[S][A]> : never;
export type CallResult<S extends ServiceName, A extends keyof Services[S]> = Services[S][A] extends Method ? Awaited<ReturnType<Services[S][A]>> : never;

/** The API the preload exposes as `window.octo`. */
export interface OctoBridge {
  call<S extends ServiceName, A extends keyof Services[S] & string>(service: S, action: A, ...args: CallArgs<S, A>): Promise<CallResult<S, A>>;
  on<K extends EventName>(channel: K, listener: (payload: Events[K]) => void): () => void;
  platform: string;
}
