import { describe, expect, it } from "vitest";
import { makeSnapshot, newID, ReviewDocument, type DiffLine, type DiffScope, type ReviewSegment } from "../src";

const snapshot = (lines: DiffLine[], scope: DiffScope = "working") =>
  makeSnapshot({ projectID: newID(), workingDirectory: "/tmp/repo", path: "renamed.swift", scope, baseRevision: "abc", lines });
const row = (segment: ReviewSegment, d: ReviewDocument) => d.text.slice(0, segment.displayRange.location).split("\n").length - 1;
const newlines = (text: string) => text.split("\n").length - 1;

describe("Side-by-side review", () => {
  it("aligns change blocks without crossing context or hunks", () => {
    const source = snapshot([
      { id: 0, kind: "header", text: "@@ -2,4 +2,3 @@" },
      { id: 1, kind: "deletion", text: "old one", oldLine: 2 },
      { id: 2, kind: "deletion", text: "old two", oldLine: 3 },
      { id: 3, kind: "addition", text: "new one", newLine: 2 },
      { id: 4, kind: "context", text: "same", oldLine: 4, newLine: 3 },
      { id: 5, kind: "header", text: "@@ -20 +19,2 @@" },
      { id: 6, kind: "addition", text: "insert", newLine: 19 },
      { id: 7, kind: "context", text: "end", oldLine: 20, newLine: 20 },
    ]);
    const pair = ReviewDocument.sideBySide(source);
    expect(pair.before.segments.map((s) => row(s, pair.before))).toEqual([0, 1, 2, 3, 4, 6]);
    expect(pair.after.segments.map((s) => row(s, pair.after))).toEqual([0, 1, 3, 4, 5, 6]);
    expect(newlines(pair.before.text)).toBe(newlines(pair.after.text));
    for (const doc of [pair.before, pair.after]) {
      expect(doc.snapshot).toEqual(source);
      const capture = doc.attachment({ location: 0, length: doc.text.length })!;
      expect(capture.snapshotID).toBe(source.id);
      expect(capture.workingDirectory).toBe(source.workingDirectory);
      expect(capture.path).toBe(source.path);
      expect(capture.text.includes("@@")).toBe(false);
    }
    expect(pair.before.attachment({ location: 0, length: pair.before.text.length })?.text).toBe("old one\nold two\nsame\nend");
    expect(pair.after.attachment({ location: 0, length: pair.after.text.length })?.text).toBe("new one\nsame\ninsert\nend");
    const gap = pair.after.segments[2].displayRange.location - 1;
    expect(pair.after.attachmentRangeForLineAt(gap, { location: 0, length: 0 })).toBeUndefined();
    expect(pair.after.attachment({ location: gap, length: 1 })).toBeUndefined();
  });

  it("keeps side-specific lines, Unicode and real blank source in selections", () => {
    const source = snapshot([
      { id: 0, kind: "deletion", text: "old 🐙 café", oldLine: 12 },
      { id: 1, kind: "addition", text: "new 🐙 café", newLine: 15 },
      { id: 2, kind: "addition", text: "", newLine: 16 },
    ], "staged");
    const pair = ReviewDocument.sideBySide(source);
    for (const doc of [pair.before, pair.after]) {
      const capture = doc.attachment({ location: doc.text.indexOf("🐙 café"), length: "🐙 café".length })!;
      expect(capture.text).toBe("🐙 café");
      expect(capture.oldLines).toEqual(doc.side === "before" ? [12, 12] : undefined);
      expect(capture.newLines).toEqual(doc.side === "after" ? [15, 15] : undefined);
      expect(capture.scope).toBe("staged");
    }
    const blank = pair.after.segments[1];
    const r = pair.after.attachmentRangeForLineAt(blank.displayRange.location, { location: 0, length: 0 })!;
    expect(pair.after.attachment(r)?.text).toBe("");
    expect(pair.after.attachment(r)?.newLines).toEqual([16, 16]);
    expect(pair.before.attachmentRangeForLineAt(pair.before.text.length - 1, r)).toBeUndefined();
  });

  it("handles added-only, deleted-only, empty and missing-newline snapshots", () => {
    for (const kind of ["addition", "deletion"] as const) {
      const pair = ReviewDocument.sideBySide(snapshot([
        { id: 0, kind, text: "source", ...(kind === "deletion" ? { oldLine: 1 } : { newLine: 1 }) },
      ]));
      const empty = kind === "addition" ? pair.before : pair.after;
      expect(empty.text).toBe("\n");
      expect(empty.attachment({ location: 0, length: 1 })).toBeUndefined();
      expect(empty.attachmentRangeForLineAt(0, { location: 0, length: 0 })).toBeUndefined();
    }
    const empty = ReviewDocument.sideBySide(snapshot([]));
    expect(empty.before.text).toBe(""); expect(empty.after.text).toBe("");
    const pair = ReviewDocument.sideBySide(snapshot([
      { id: 0, kind: "deletion", text: "old", oldLine: 1 },
      { id: 1, kind: "header", text: "\\ No newline at end of file" },
      { id: 2, kind: "addition", text: "new", newLine: 1 },
    ]));
    expect(row(pair.before.segments[0], pair.before)).toBe(row(pair.after.segments[0], pair.after));
    expect(pair.before.attachment(pair.before.segments[1].contentRange)).toBeUndefined();
  });
});
