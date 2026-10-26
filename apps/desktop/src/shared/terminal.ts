import type { SplitLayout } from "@octo/core";

export interface TerminalTabState {
  id: string;
  projectID: string;
  directory: string;
  /** The automatic label: "Terminal", or the file the editor opened. */
  label: string;
  /** Set by the user; overrides the label until cleared. */
  customName?: string;
  /** The last pane's process has ended. */
  exited: boolean;
  /** Panes in creation order. Layout changes never reorder them, so no surface is remounted. */
  panes: string[];
  layout: SplitLayout;
  focusedPane: string;
  /** The tab runs Octo's own Neovim, reachable through its socket. */
  editor: boolean;
}

export interface TerminalSetupState {
  pane: string;
  title: string;
  exited: boolean;
}

export interface TerminalWorkspaceState {
  version: number;
  tabs: TerminalTabState[];
  /** The selected tab per project. */
  selected: Record<string, string>;
  setup?: TerminalSetupState;
}

/** Main → renderer terminal events. Output and exits are tagged with their pane. */
export type TerminalEvent =
  | { type: "workspace"; workspace: TerminalWorkspaceState }
  | { type: "output"; pane: string; data: string; cursor: number }
  | { type: "exit"; pane: string }
  | { type: "focus"; pane: string };

/** What a close needs before it ends running programs. */
export type CloseResult = { closed: true } | { closed: false; confirm: string };

/** The subset of the user's Ghostty configuration the web terminal honors. */
export interface GhosttyConfig {
  theme?: string;
  fontFamily?: string;
  fontSize?: number;
  /** `[trigger, action]` pairs from `keybind = trigger=action`, in file order. */
  keybinds: [string, string][];
  unfocusedSplitOpacity: number;
  unfocusedSplitFill?: string;
  splitDivider?: string;
  diagnostics: string[];
}

/** Gives the renderer the scrollback it missed, for panes that mount late or after a reload. */
export interface TerminalSnapshot {
  workspace: TerminalWorkspaceState;
  replay: Record<string, string>;
  /** UTF-16 stream ends; events at or before these cursors are already in replay. */
  cursors: Record<string, number>;
  exited: string[];
}
