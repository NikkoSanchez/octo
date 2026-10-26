import { describe, expect, it } from "vitest";
import { formatAccelerator, menuShortcutMatches } from "./menu";

const press = (code: string, modifiers: Partial<{ meta: boolean; control: boolean; shift: boolean; alt: boolean }> = {}) =>
  ({ code, meta: false, control: false, shift: false, alt: false, ...modifiers });

describe("menu shortcuts", () => {
  it("matches physical keys with exactly the accelerator's modifiers on macOS", () => {
    expect(menuShortcutMatches("CommandOrControl+K", press("KeyK", { meta: true }), true)).toBe(true);
    expect(menuShortcutMatches("CommandOrControl+K", press("KeyK", { meta: true, shift: true }), true)).toBe(false);
    expect(menuShortcutMatches("CommandOrControl+Shift+K", press("KeyK", { meta: true, shift: true }), true)).toBe(true);
    expect(menuShortcutMatches("CommandOrControl+Alt+[", press("BracketLeft", { meta: true, alt: true }), true)).toBe(true);
    expect(menuShortcutMatches("CommandOrControl+Shift+Enter", press("Enter", { meta: true, shift: true }), true)).toBe(true);
  });

  it("leaves Control combinations to the terminal unless the accelerator asks for them", () => {
    expect(menuShortcutMatches("CommandOrControl+B", press("KeyB", { meta: true, control: true }), true)).toBe(false);
    expect(menuShortcutMatches("CommandOrControl+Control+=", press("Equal", { meta: true, control: true }), true)).toBe(true);
    expect(menuShortcutMatches("CommandOrControl+Control+=", press("Equal", { meta: true }), true)).toBe(false);
  });

  it("uses Ctrl for CommandOrControl elsewhere", () => {
    expect(menuShortcutMatches("CommandOrControl+K", press("KeyK", { control: true }), false)).toBe(true);
    expect(menuShortcutMatches("CommandOrControl+K", press("KeyK", { meta: true }), false)).toBe(false);
  });

  it("formats accelerators with macOS symbols in Apple's modifier order", () => {
    expect(formatAccelerator("CommandOrControl+Alt+B", true)).toBe("⌥⌘B");
    expect(formatAccelerator("CommandOrControl+Shift+Enter", true)).toBe("⇧⌘↩");
    expect(formatAccelerator("CommandOrControl+Control+=", true)).toBe("⌃⌘=");
  });
});
