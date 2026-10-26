import { describe, expect, it } from "vitest";
import { makeSnapshot } from "@octo/core";
import { parsePatchFiles } from "@pierre/diffs";
import { captureDiff, captureFile, hunkAnnotations, snapshotPatch } from "./reviewCapture";
const snapshot = makeSnapshot({ projectID: "P", workingDirectory: "/checkout", path: 'space 🐙.ts', scope: "working", baseRevision: "HEAD", lines: [
  { id: 0, kind: "header", text: "@@ -7,2 +7,2 @@" }, { id: 1, kind: "context", text: "same", oldLine: 7, newLine: 7 },
  { id: 2, kind: "deletion", text: "old 🐙", oldLine: 8 }, { id: 3, kind: "addition", text: "new 🐙", newLine: 8 },
] });
describe("Pierre capture mapping", () => {
  it("captures either side without gutters or opposite-side content", () => {
    const old = captureDiff(snapshot, { start: 7, end: 8, side: "deletions" })!;
    expect(old.text).toBe("same\nold 🐙"); expect(old.oldLines).toEqual([7,8]); expect(old.newLines).toBeUndefined();
    const next = captureDiff(snapshot, { start: 8, end: 7, side: "additions" })!;
    expect(next.text).toBe("same\nnew 🐙"); expect(next.newLines).toEqual([7,8]); expect(next.snapshotID).toBe(snapshot.id); expect(next.workingDirectory).toBe("/checkout");
    expect(captureDiff(snapshot, { start: 100, end: 101 })).toBeUndefined();
  });
  it("keeps both ranges for a cross-side selection", () => {
    const a = captureDiff(snapshot, { start: 8, side: "deletions", end: 8, endSide: "additions" })!;
    expect(a.text).toBe("old 🐙\nnew 🐙"); expect(a.oldLines).toEqual([8,8]); expect(a.newLines).toEqual([8,8]);
  });
  it("preserves exact UTF-16 source and line endings for file captures", () => {
    const a = captureFile("first\r\n🐙 next\r\nlast", snapshot, { start: 1, end: 2 })!;
    expect(a.text).toBe("first\r\n🐙 next"); expect(a.newLines).toEqual([1,2]); expect(a.scope).toBe("file");
  });
  it("parses display patches with quoted paths and untracked additions", () => {
    expect(parsePatchFiles(snapshotPatch(snapshot), snapshot.id, true)[0].files[0].hunks).toHaveLength(1);
    const untracked = { ...snapshot, lines: [{ id: 0, kind: "addition" as const, newLine: 1, text: "new" }] };
    expect(parsePatchFiles(snapshotPatch(untracked), "untracked", true)[0].files[0].additionLines.join("")).toContain("new");
  });
  it("places each hunk's action above the hunk, on the line before its header", () => {
    const twoHunks = { ...snapshot, lines: [
      ...snapshot.lines,
      { id: 4, kind: "header" as const, text: "@@ -20,1 +20,0 @@" }, { id: 5, kind: "deletion" as const, text: "gone", oldLine: 20 },
      { id: 6, kind: "header" as const, text: "@@ -30,1 +29,1 @@" }, { id: 7, kind: "context" as const, text: "kept", oldLine: 30, newLine: 29 },
    ] };
    expect(hunkAnnotations(twoHunks)).toEqual([
      { side: "additions", lineNumber: 0, metadata: { hunk: 0, index: 0 } },
      { side: "additions", lineNumber: 8, metadata: { hunk: 4, index: 1 } },
      { side: "deletions", lineNumber: 20, metadata: { hunk: 6, index: 2 } },
    ]);
  });
});
