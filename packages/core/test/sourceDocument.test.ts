import { describe, expect, it } from "vitest";
import { makeSnapshot, newID, NOT_FOUND, SourceDocument } from "../src";

const context = makeSnapshot({ projectID: newID(), workingDirectory: "/tmp/checkout", path: "file.swift", scope: "file", baseRevision: "abc", lines: [] });

describe("SourceDocument", () => {
  it("keeps exact Unicode, CRLF selections and boundary lines", () => {
    const text = "let 🐙 = 1\r\n\r\nlast";
    const document = new SourceDocument(text, context);
    const selected = { location: text.indexOf("🐙 = 1\r\n\r\n"), length: "🐙 = 1\r\n\r\n".length };
    const capture = document.attachment(selected)!;
    expect(capture.text).toBe("🐙 = 1\r\n\r\n");
    expect(capture.newLines).toEqual([1, 2]); expect(capture.oldLines).toBeUndefined();
    expect(capture.workingDirectory).toBe(context.workingDirectory);
    expect(capture.baseRevision).toBe("abc"); expect(capture.scope).toBe("file");
    const blank = document.attachmentRangeForLineAt(document.segments[1].displayRange.location, { location: 0, length: 0 })!;
    expect(document.attachment(blank)?.newLines).toEqual([2, 2]);
    expect(document.attachment(blank)?.text).toBe("\r\n");
    expect(document.attachmentRangeForLineAt(0, selected)).toEqual(selected);
    expect(document.attachment({ location: NOT_FOUND, length: 1 })).toBeUndefined();
    expect(document.attachment({ location: 0, length: Number.MAX_SAFE_INTEGER })).toBeUndefined();
  });

  it("captures unsaved source and line endings in snapshots", () => {
    const a = new SourceDocument("one\ntwo\n", context);
    const b = new SourceDocument("one\r\ntwo\r\n", context);
    const c = new SourceDocument("one\ntwo", context);
    expect(a.snapshot.id).not.toBe(b.snapshot.id); expect(a.snapshot.id).not.toBe(c.snapshot.id);
    const capture = a.attachment({ location: 4, length: 3 })!;
    expect(capture.text).toBe("two"); expect(capture.newLines).toEqual([2, 2]);
    const changed = new SourceDocument("new\none\ntwo\n", context);
    expect(changed.snapshot.id).not.toBe(capture.snapshotID);
    expect(new SourceDocument("", context).segments.length).toBe(1);
  });
});
