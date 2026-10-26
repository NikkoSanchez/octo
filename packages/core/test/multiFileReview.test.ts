import { describe, expect, it } from "vitest";
import { makeSnapshot, newID, ReviewDocument, type DiffLine, type DiffScope } from "../src";

const project = newID();
const snapshot = (path: string, lines: DiffLine[], scope: DiffScope = "working", notice?: string) =>
  makeSnapshot({ projectID: project, workingDirectory: "/repo", path, scope, baseRevision: "abc", lines, ...(notice ? { notice } : {}) });

function fixture(): ReviewDocument {
  const a = snapshot("Sources/A.swift", [{ id: 0, kind: "header", text: "@@ -1,2 +1,2 @@" },
    { id: 1, kind: "deletion", text: "old a", oldLine: 1 }, { id: 2, kind: "addition", text: "new a", newLine: 1 }]);
  const b = snapshot("B.md", [{ id: 0, kind: "header", text: "@@ -5 +5 @@" }, { id: 1, kind: "addition", text: "new b", newLine: 5 },
    { id: 2, kind: "header", text: "@@ -9 +9 @@" }, { id: 3, kind: "context", text: "same", oldLine: 9, newLine: 9 }], "staged");
  const image = snapshot("image.png", [], "working", "Binary file changed.");
  return ReviewDocument.fromFiles([a, b, image]);
}
const rangeOf = (needle: string, d: ReviewDocument) => ({ location: d.text.indexOf(needle), length: needle.length });

describe("Multi-file review", () => {
  it("gives files title rows and keeps their own snapshots in captures", () => {
    const document = fixture();
    expect(document.isMultiFile).toBe(true);
    expect(document.files.map((f) => f.snapshot.path)).toEqual(["Sources/A.swift", "B.md", "image.png"]);
    expect(document.text.startsWith("Sources/A.swift  ·  Unstaged\n")).toBe(true);
    expect(document.text.includes("\n\nB.md  ·  Staged\n")).toBe(true);
    expect(document.text.includes("Binary file changed.")).toBe(true);
    const captured = document.attachment(rangeOf("new b", document));
    expect(captured?.path).toBe("B.md");
    expect(captured?.scope).toBe("staged");
    expect(captured?.newLines).toEqual([5, 5]);
    expect(captured?.snapshotID).toBe(document.files[1].snapshot.id);
    const start = rangeOf("old a", document), end = rangeOf("new b", document);
    const spanning = document.attachment({ location: start.location, length: end.location + end.length - start.location });
    expect(spanning?.path).toBe("Sources/A.swift");
    expect(spanning?.text).toBe("old a\nnew a");
    expect(document.attachment(rangeOf("B.md  ·  Staged", document))).toBeUndefined();
    expect(document.attachmentRangeForLineAt(rangeOf("B.md  ·", document).location, { location: 0, length: 0 })).toBeUndefined();
    expect(document.attachment(rangeOf("Binary file changed.", document))).toBeUndefined();
  });

  it("keeps hunks within their file", () => {
    const document = fixture();
    const headerB = document.segments.findIndex((s) => s.file === 1 && s.line.id === 0);
    const secondB = document.segments.findIndex((s) => s.file === 1 && s.line.id === 2);
    expect(document.hunkHeaderAt(rangeOf("new b", document).location)).toBe(headerB);
    expect(document.hunkHeaderAt(rangeOf("same", document).location)).toBe(secondB);
    expect(document.segments[secondB].file).toBe(1);
    expect(document.hunkHeaderAt(rangeOf("B.md  ·", document).location)).toBeUndefined();
    expect(document.hunkHeaderAt(rangeOf("Binary", document).location)).toBeUndefined();
    expect(document.fileAt(rangeOf("B.md  ·", document).location)).toBe(1);
    expect(document.fileAt(rangeOf("old a", document).location)).toBe(0);
    expect(document.fileAt(document.text.length)).toBeUndefined();
  });

  it("follows every file in its identity", () => {
    const one = fixture(), two = fixture();
    expect(one.snapshot.id).toBe(two.snapshot.id);
    const files = one.files.map((f) => f.snapshot);
    files[1] = snapshot("B.md", [{ id: 0, kind: "addition", text: "changed", newLine: 5 }], "staged");
    expect(ReviewDocument.fromFiles(files).snapshot.id).not.toBe(one.snapshot.id);
    expect(ReviewDocument.fromFiles([]).text).toBe("");
    const single = ReviewDocument.fromSnapshot(files[0]);
    expect(single.isMultiFile).toBe(false);
    expect(single.files.length).toBe(1);
    expect(single.hunkHeaderAt(0)).toBe(0);
  });
});
