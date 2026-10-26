import { create } from "zustand";

export type PaletteMode = "projects" | "chats" | "commands" | "files";
export type SidebarEditKind = "rename" | "remove";
export interface SidebarEdit { kind: SidebarEditKind; projectID: string; threadID?: string }
export interface FileAction { kind: "create" | "delete"; projectID: string; root: string; path: string }
export type SettingsTab = "appearance" | "keyboard" | "agents";

const SIDEBAR_KEY = "octo.sidebarWidth";
const storedWidth = Number(localStorage.getItem(SIDEBAR_KEY));

export const SIDEBAR_MIN = 240, SIDEBAR_MAX = 320;
export { SIDEBAR_THREAD_INITIAL, SIDEBAR_THREAD_PAGE } from "../lib/sidebar";
/** Below this width the review card covers the chat instead of sitting beside it. */
export const SINGLE_REVIEW_WIDTH = 737;

interface UIState {
  showingTerminal: boolean;
  showingReview: boolean;
  sidebarOpen: boolean;
  compactSidebarOpen: boolean;
  sidebarWidth: number;
  palette: PaletteMode | null;
  settings: SettingsTab | null;
  usageDashboard: boolean;
  /** The project actions popover from the titlebar capsule, when the card does not float. */
  projectActions: boolean;
  /** A renderer-side failure, shown in the same alert as the store's. */
  error: string | null;
  /** Draft text per thread; attachments live in main. */
  drafts: Record<string, string>;
  /** Each increment asks the composer to take focus. */
  composerFocus: number;
  /** Each increment asks the review pane's content to take focus. */
  reviewFocus: number;
  /** Each increment (⌘K while the sidebar shows) starts searching in the sidebar. */
  sidebarSearchRequest: number;
  sidebarThreadLimits: Record<string, number>;
  sidebarEdit: SidebarEdit | null;
  fileAction: FileAction | null;
  renamingTerminal: string | null;
  findingThread: boolean;
  /** Each increment refocuses the find field. */
  findFocus: number;
  /** ⌘G and ⇧⌘G steps, consumed by the open transcript. */
  findStep: { delta: number; request: number };
  /** Each increment asks the composer to send, as ⌘Return. */
  sendRequest: number;
  shortcutHints: boolean;
  /** A file and line to reveal in the editor, from a Markdown link. */
  reviewLocation?: { root: string; path: string; line: number; request: number };
  /** Open overlays. Browser pages are native views above the page, so they hide while any is open. */
  overlays: string[];

  showError(message: string): void;
  setDraft(threadID: string, text: string): void;
  focusComposer(): void;
  showTerminal(visible: boolean): void;
  setSidebarWidth(width: number): void;
  openOverlay(name: string): void;
  closeOverlay(name: string): void;
}

export const useUI = create<UIState>((set) => ({
  showingTerminal: false,
  showingReview: false,
  sidebarOpen: true,
  compactSidebarOpen: false,
  sidebarWidth: Number.isFinite(storedWidth) && storedWidth >= SIDEBAR_MIN && storedWidth <= SIDEBAR_MAX ? storedWidth : 290,
  palette: null,
  settings: null,
  usageDashboard: false,
  projectActions: false,
  error: null,
  drafts: {},
  composerFocus: 0,
  reviewFocus: 0,
  sidebarSearchRequest: 0,
  sidebarThreadLimits: {},
  sidebarEdit: null,
  fileAction: null,
  renamingTerminal: null,
  findingThread: false,
  findFocus: 0,
  findStep: { delta: 0, request: 0 },
  sendRequest: 0,
  shortcutHints: false,
  overlays: [],

  showError: (message) => set({ error: message }),
  setDraft: (threadID, text) => set((s) => ({ drafts: { ...s.drafts, [threadID]: text } })),
  // A review card covering the chat gives way to the composer.
  focusComposer: () => set((s) => ({
    showingTerminal: false,
    compactSidebarOpen: false,
    showingReview: workspaceLayout(window.innerWidth, s).detailWidth < SINGLE_REVIEW_WIDTH ? false : s.showingReview,
    composerFocus: s.composerFocus + 1,
  })),
  showTerminal: (visible) => set({ showingTerminal: visible, compactSidebarOpen: false }),
  setSidebarWidth: (width) => {
    const clamped = Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, width));
    localStorage.setItem(SIDEBAR_KEY, String(Math.round(clamped)));
    set({ sidebarWidth: clamped });
  },
  openOverlay: (name) => set((s) => (s.overlays.includes(name) ? s : { overlays: [...s.overlays, name] })),
  closeOverlay: (name) => set((s) => ({ overlays: s.overlays.filter((o) => o !== name) })),
}));

/** Geometry is independent of child sizes so a hidden pane never sets the window minimum. */
export function workspaceLayout(width: number, ui: Pick<UIState, "sidebarWidth" | "sidebarOpen" | "compactSidebarOpen">) {
  const compact = width < 800;
  const sidebarVisible = compact ? ui.compactSidebarOpen : ui.sidebarOpen;
  const overlayVisible = compact && ui.compactSidebarOpen;
  const detailOffset = !compact && ui.sidebarOpen ? ui.sidebarWidth + 7 : 0;
  return { width, compact, sidebarVisible, overlayVisible, detailOffset, detailWidth: Math.max(0, width - detailOffset), sidebarWidth: ui.sidebarWidth };
}
export type WorkspaceLayout = ReturnType<typeof workspaceLayout>;

/** Hides the compact overlay or the docked sidebar, as ⌘B does. */
export function toggleSidebar(): void {
  const s = useUI.getState();
  if (workspaceLayout(window.innerWidth, s).compact) useUI.setState({ compactSidebarOpen: !s.compactSidebarOpen });
  else useUI.setState({ sidebarOpen: !s.sidebarOpen });
}

/** True while something covers the workspace, so native browser views and the chat stand aside. */
export function useCovered(): boolean {
  return useUI((s) => s.overlays.length > 0 || !!s.palette || !!s.settings || !!s.sidebarEdit || !!s.error || !!s.fileAction || s.usageDashboard);
}
