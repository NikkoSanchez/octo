import { create } from "zustand";
import type { BrowserState } from "../../../shared/browser";
import { call, on } from "../bridge";

/** Every browser tab's page state as main reports it, for the panes and their tab chips. */
export const useBrowsers = create<{ pages: Record<string, BrowserState>; focusAddress: Record<string, number> }>(() => ({ pages: {}, focusAddress: {} }));

let listening = false;
function listen(): void {
  if (listening) return;
  listening = true;
  on("browser:event", (event) => {
    if (event.type === "state") useBrowsers.setState((s) => ({ pages: { ...s.pages, [event.state.id]: event.state } }));
    else if (event.type === "closed") useBrowsers.setState((s) => { const pages = { ...s.pages }; delete pages[event.id]; return { pages }; });
    else useBrowsers.setState((s) => ({ focusAddress: { ...s.focusAddress, [event.id]: (s.focusAddress[event.id] ?? 0) + 1 } }));
  });
}

/** Main creates a tab's page on first display; a restored tab loads when first shown. */
export async function openBrowserPage(id: string, projectID: string): Promise<void> {
  listen();
  if (useBrowsers.getState().pages[id]) return;
  const state = await call("browser", "create", id, projectID);
  useBrowsers.setState((s) => (s.pages[id] ? s : { pages: { ...s.pages, [id]: state } }));
}

/** The tab chip's title: the page's, else its host, else Private or New Tab. */
export function browserTitle(page: BrowserState | undefined, isPrivate: boolean): string {
  if (page?.title) return page.title;
  if (page?.url) { try { return new URL(page.url).host || page.url; } catch { return page.url; } }
  return isPrivate ? "Private" : "New Tab";
}
