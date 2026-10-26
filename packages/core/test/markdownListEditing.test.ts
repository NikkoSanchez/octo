import { describe, expect, it } from "vitest";
import { MarkdownListEditing, type ListEdit, type TextRange } from "../src";

/** `|` marks the caret; `«` and `»` mark a selection. */
function parse(marked: string): [string, TextRange] {
  const caret = marked.indexOf("|");
  if (caret !== -1) return [marked.slice(0, caret) + marked.slice(caret + 1), { location: caret, length: 0 }];
  const open = marked.indexOf("«");
  let text = marked.slice(0, open) + marked.slice(open + 1);
  const close = text.indexOf("»");
  text = text.slice(0, close) + text.slice(close + 1);
  return [text, { location: open, length: close - open }];
}
function apply(edit: ListEdit | undefined, text: string): string | undefined {
  if (!edit) return undefined;
  const result = MarkdownListEditing.apply(text, edit);
  if (edit.selection.length !== 0) return result;
  return result.slice(0, edit.selection.location) + "|" + result.slice(edit.selection.location);
}
const newline = (m: string) => { const [t, s] = parse(m); return apply(MarkdownListEditing.newline(t, s), t); };
const indent = (m: string) => { const [t, s] = parse(m); return apply(MarkdownListEditing.indent(t, s), t); };
const outdent = (m: string) => { const [t, s] = parse(m); return apply(MarkdownListEditing.outdent(t, s), t); };

describe("MarkdownListEditing", () => {
  it("continues bullets, numbers, tasks and quotes on Shift-Return", () => {
    expect(newline("- one|")).toBe("- one\n- |");
    expect(newline("Intro\n* one|")).toBe("Intro\n* one\n* |");
    expect(newline("1. one|")).toBe("1. one\n2. |");
    expect(newline("9) nine|")).toBe("9) nine\n10) |");
    expect(newline("  - nested|")).toBe("  - nested\n  - |");
    expect(newline("- [x] done|")).toBe("- [x] done\n- [ ] |");
    expect(newline("> quoted|")).toBe("> quoted\n> |");
    expect(newline("- one| two")).toBe("- one\n- | two");
  });

  it("ends or steps out of the list on an empty item", () => {
    expect(newline("- one\n- |")).toBe("- one\n|");
    expect(newline("- one\n- [ ] |")).toBe("- one\n|");
    expect(newline("> |")).toBe("|");
    expect(newline("1. one\n   1. |")).toBe("1. one\n2. |");
  });

  it("leaves plain text and carets inside the marker to the text view", () => {
    expect(newline("Just text|")).toBeUndefined();
    expect(newline("-1 is negative|")).toBeUndefined();
    expect(newline("2.5 is a number|")).toBeUndefined();
    expect(newline("-| one")).toBeUndefined();
    expect(MarkdownListEditing.isInList("Just text", { location: 4, length: 0 })).toBe(false);
    expect(MarkdownListEditing.isInList("a\n- b", { location: 4, length: 0 })).toBe(true);
    expect(MarkdownListEditing.isInList("> quote", { location: 4, length: 0 })).toBe(false);
  });

  it("nests under the item above, aligned with its content, on Tab", () => {
    expect(indent("- one\n- two|")).toBe("- one\n  - two|");
    expect(indent("1. one\n2. two|")).toBe("1. one\n   1. two|");
    expect(indent("1. one\n   1. a\n2. b|")).toBe("1. one\n   1. a\n   2. b|");
    expect(indent("- one\n- |")).toBe("- one\n  - |");
    expect(indent("- one\n|- two")).toBe("- one\n  - |two");
    expect(indent("- one|")).toBeUndefined();
    expect(indent("Text\n- one|")).toBeUndefined();
    expect(indent("one\ntwo|")).toBeUndefined();
  });

  it("moves out to the parent level, numbered after it, on Shift-Tab", () => {
    expect(outdent("- one\n  - two|")).toBe("- one\n- two|");
    expect(outdent("1. one\n   1. two|")).toBe("1. one\n2. two|");
    expect(outdent("- a\n  - b\n    - c|")).toBe("- a\n  - b\n  - c|");
    expect(outdent("- top|")).toBeUndefined();
  });

  it("indents every selected item", () => {
    const [text, selection] = parse("- one\n«- two\n- three»");
    const edit = MarkdownListEditing.indent(text, selection)!;
    const result = MarkdownListEditing.apply(text, edit);
    expect(result).toBe("- one\n  - two\n  - three");
    expect(result.substr(edit.selection.location, edit.selection.length)).toBe("  - two\n  - three");
  });

  it("counts UTF-16", () => {
    expect(newline("- 👋🏽 hi|")).toBe("- 👋🏽 hi\n- |");
    expect(indent("- 日本\n- 👋🏽|")).toBe("- 日本\n  - 👋🏽|");
  });
});
