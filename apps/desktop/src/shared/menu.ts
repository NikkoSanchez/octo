/** A workspace command as the application menu shows it. The renderer owns the commands and their keys. */
export interface MenuCommand {
  id: string;
  title: string;
  group: string;
  /** An Electron accelerator for display; the renderer's key router handles the key itself. */
  accelerator?: string;
  enabled: boolean;
}

export const MENU_GROUPS = ["Navigate", "Panels", "Conversation", "Review", "Terminal"] as const;

/**
 * A native popup or context menu item. Choosing one resolves the popup with its `id`. `icon` is an
 * image data URL; without one, macOS draws the SF Symbol `symbol` names in the menu's own colour.
 */
export type PopupItem =
  | { type?: "item"; id: string; label: string; enabled?: boolean; checked?: boolean; toolTip?: string; accelerator?: string; icon?: string; symbol?: string }
  | { type: "separator" }
  | { type: "header"; label: string }
  | { type: "submenu"; label: string; enabled?: boolean; icon?: string; symbol?: string; items: PopupItem[] };

export interface ShortcutInput { code: string; meta: boolean; control: boolean; shift: boolean; alt: boolean }
const KEY_CODES: Record<string, string> = {
  left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown", "[": "BracketLeft", "]": "BracketRight",
  ",": "Comma", ".": "Period", "\\": "Backslash", "=": "Equal", "-": "Minus", "/": "Slash", enter: "Enter", return: "Enter", escape: "Escape",
};

/**
 * Whether a key press is this accelerator, by physical key so layouts and Shift don't change the
 * character. Used by the renderer's key router and by main while a native browser page has focus.
 */
export function menuShortcutMatches(accelerator: string | undefined, input: ShortcutInput, mac: boolean): boolean {
  if (!accelerator) return false;
  const parts = accelerator.toLowerCase().split("+"), key = parts.pop()!;
  const primary = parts.includes("commandorcontrol") || parts.includes("command") || parts.includes("cmd");
  const control = parts.includes("control") || parts.includes("ctrl");
  // On macOS CommandOrControl is ⌘ and Control is ⌃; elsewhere both are Ctrl.
  const wantsMeta = mac && primary, wantsControl = mac ? control : primary || control;
  if (input.meta !== wantsMeta || input.control !== wantsControl) return false;
  const code = KEY_CODES[key] ?? (/^[a-z]$/.test(key) ? `Key${key.toUpperCase()}` : /^[0-9]$/.test(key) ? `Digit${key}` : key);
  return input.code.toLowerCase() === code.toLowerCase() && input.shift === parts.includes("shift") && input.alt === (parts.includes("alt") || parts.includes("option"));
}

/** User-visible shortcuts use the platform's key names, separate from Electron's binding syntax. */
export function formatAccelerator(accelerator: string | undefined, mac: boolean): string {
  if (!accelerator) return "";
  const parts = accelerator.split("+"), key = parts.pop()!;
  if (!mac) return [...parts.map((p) => p === "CommandOrControl" ? "Ctrl" : p), key].join("+");
  const has = (...names: string[]) => parts.some((p) => names.includes(p.toLowerCase()));
  const symbols: Record<string, string> = { left: "←", right: "→", up: "↑", down: "↓", enter: "↩", escape: "⎋" };
  return (has("control", "ctrl") ? "⌃" : "") + (has("alt", "option") ? "⌥" : "") + (has("shift") ? "⇧" : "") + (has("commandorcontrol", "command", "cmd", "super") ? "⌘" : "") + (symbols[key.toLowerCase()] ?? key.toUpperCase());
}
