/**
 * Where "Open in" can send a checkout or a reviewed file. Neovim runs in Octo's terminal with the
 * user's own configuration; every other target is an installed app opened through Launch Services.
 */
export interface OpenTarget {
  id: string;
  title: string;
  kind: "neovim" | "finder" | "app";
  bundleID?: string;
}

export const OPEN_TARGETS: OpenTarget[] = [
  { id: "neovim", title: "Neovim", kind: "neovim" },
  { id: "cursor", title: "Cursor", kind: "app", bundleID: "com.todesktop.230313mzl4w4u92" },
  { id: "vscode", title: "VS Code", kind: "app", bundleID: "com.microsoft.VSCode" },
  { id: "vscode-insiders", title: "VS Code Insiders", kind: "app", bundleID: "com.microsoft.VSCodeInsiders" },
  { id: "zed", title: "Zed", kind: "app", bundleID: "dev.zed.Zed" },
  { id: "windsurf", title: "Windsurf", kind: "app", bundleID: "com.exafunction.windsurf" },
  { id: "sublime", title: "Sublime Text", kind: "app", bundleID: "com.sublimetext.4" },
  { id: "xcode", title: "Xcode", kind: "app", bundleID: "com.apple.dt.Xcode" },
  { id: "finder", title: "Finder", kind: "finder" },
  { id: "terminal", title: "Terminal", kind: "app", bundleID: "com.apple.Terminal" },
  { id: "ghostty", title: "Ghostty", kind: "app", bundleID: "com.mitchellh.ghostty" },
  { id: "iterm", title: "iTerm", kind: "app", bundleID: "com.googlecode.iterm2" },
  { id: "warp", title: "Warp", kind: "app", bundleID: "dev.warp.Warp-Stable" },
];

/** The saved choice, or Neovim. Earlier versions saved Neovim as "lazyvim". */
export function savedTarget(id: string | undefined): string {
  return !id || id === "lazyvim" ? "neovim" : id;
}

export function preferredTarget(id: string): OpenTarget {
  return OPEN_TARGETS.find((t) => t.id === id) ?? OPEN_TARGETS[0];
}

/** Editors that open `scheme://file/<path>:<line>` at that line. */
export function fileScheme(target: OpenTarget): string | undefined {
  return ["cursor", "vscode", "vscode-insiders", "zed", "windsurf"].includes(target.id) ? target.id : undefined;
}

/** Terminals receive the checkout directory rather than a file: opening a script in one runs it. */
export function isTerminalTarget(target: OpenTarget): boolean {
  return ["terminal", "ghostty", "iterm", "warp"].includes(target.id);
}

export interface AvailableTarget extends OpenTarget {
  /** A data URL of the app's icon, when one could be read. */
  icon?: string;
}

/** The SF Symbol shown where a target has no app icon. */
export function targetSymbol(target: OpenTarget): string {
  return target.kind === "neovim" ? "terminal" : target.kind === "finder" ? "folder" : "app";
}
