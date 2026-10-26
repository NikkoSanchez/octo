import { describe, expect, it } from "vitest";
import {
  decodeArchive, decodeMessage, encodeArchive, encodeMessage, makeArchive, makeImage, makeMessage, makeProject, makeSnapshot, makeThread,
  newID, NOT_FOUND, orderedProjects, orderedThreads, removeProject, removeThread, ReviewDocument, DISTANT_FUTURE,
  type DiffLine,
} from "../src";

const snapshot = (lines: DiffLine[]) => makeSnapshot({ projectID: newID(), workingDirectory: "/tmp/repo", path: "code.swift", scope: "working", baseRevision: "abc", lines });
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const roundTrip = (value: unknown): any => JSON.parse(JSON.stringify(value));

describe("Review", () => {
  it("preserves Unicode source and excludes gutters in selections", () => {
    const document = ReviewDocument.fromSnapshot(snapshot([
      { id: 0, kind: "header", text: "@@ -1 +1 @@" },
      { id: 1, kind: "deletion", text: "let old = 1", oldLine: 1 },
      { id: 2, kind: "addition", text: "let octo = \"🐙 café\"", newLine: 1 },
    ]));
    const at = document.text.indexOf("🐙 café");
    const attachment = document.attachment({ location: at, length: "🐙 café".length });
    expect(attachment?.text).toBe("🐙 café");
    expect(attachment?.newLines).toEqual([1, 1]);
    expect(attachment?.oldLines).toBeUndefined();
    const all = document.attachment({ location: 0, length: document.text.length });
    expect(all?.text).toBe("let old = 1\nlet octo = \"🐙 café\"");
    expect(all?.oldLines).toEqual([1, 1]);
    expect(all?.snapshotID).toBe(document.snapshot.id);
    expect(document.attachment({ location: 0, length: 5 })).toBeUndefined();
    expect(document.attachment({ location: NOT_FOUND, length: 0 })).toBeUndefined();
  });

  it("changes snapshot identity with content and scope", () => {
    const a = snapshot([{ id: 0, kind: "addition", text: "a", newLine: 1 }]);
    const b = snapshot([{ id: 0, kind: "addition", text: "b", newLine: 1 }]);
    expect(a.id).not.toBe(b.id);
    expect(makeSnapshot({ ...a, lines: a.lines }).id).toBe(a.id);
    expect(makeSnapshot({ ...a, scope: "file" }).id).not.toBe(a.id);
  });

  it("captures source lines on hover and rejects headers", () => {
    const doc = ReviewDocument.fromSnapshot(snapshot([
      { id: 0, kind: "header", text: "@@ -4,1 +4,2 @@" },
      { id: 1, kind: "deletion", text: "old 🐙", oldLine: 4 },
      { id: 2, kind: "addition", text: "new café", newLine: 4 },
      { id: 3, kind: "addition", text: "", newLine: 5 },
    ]));
    const empty = { location: NOT_FOUND, length: 0 };
    expect(doc.attachmentRangeForLineAt(0, empty)).toBeUndefined();
    expect(doc.attachmentRangeForLineAt(-1, empty)).toBeUndefined();
    expect(doc.attachmentRangeForLineAt(doc.text.length, empty)).toBeUndefined();
    for (let index = 1; index <= 3; index++) {
      const segment = doc.segments[index];
      for (const offset of [segment.displayRange.location, segment.contentRange.location, segment.displayRange.location + segment.displayRange.length - 1]) {
        const r = doc.attachmentRangeForLineAt(offset, empty)!;
        const attachment = doc.attachment(r)!;
        expect(attachment.text).toBe(segment.line.text);
        expect(attachment.oldLines).toEqual(segment.line.oldLine !== undefined ? [segment.line.oldLine, segment.line.oldLine] : undefined);
        expect(attachment.newLines).toEqual(segment.line.newLine !== undefined ? [segment.line.newLine, segment.line.newLine] : undefined);
        expect(attachment.path).toBe(doc.snapshot.path);
        expect(attachment.workingDirectory).toBe(doc.snapshot.workingDirectory);
        expect(attachment.snapshotID).toBe(doc.snapshot.id);
      }
    }
  });

  it("uses an intersecting selection only on hover", () => {
    const doc = ReviewDocument.fromSnapshot(snapshot([
      { id: 0, kind: "context", text: "first 🐙", oldLine: 1, newLine: 1 },
      { id: 1, kind: "context", text: "", oldLine: 2, newLine: 2 },
      { id: 2, kind: "context", text: "third", oldLine: 3, newLine: 3 },
    ]));
    const start = doc.text.indexOf("🐙");
    const selection = { location: start, length: doc.segments[2].displayRange.location - start };
    for (const index of [0, 1]) {
      const r = doc.attachmentRangeForLineAt(doc.segments[index].displayRange.location, selection)!;
      expect(r).toEqual(selection);
      expect(doc.attachment(r)?.text).toBe("🐙\n");
      expect(doc.attachment(r)?.newLines).toEqual([1, 2]);
    }
    const outside = doc.attachmentRangeForLineAt(doc.segments[2].displayRange.location, selection)!;
    expect(doc.attachment(outside)?.text).toBe("third");
    const line = doc.attachmentRangeForLineAt(0, { location: 0, length: 5 })!;
    expect(doc.attachment(line)?.text).toBe("first 🐙");
  });

  it("keeps empty source lines in multiline selections", () => {
    const doc = ReviewDocument.fromSnapshot(snapshot([
      { id: 0, kind: "context", text: "first", newLine: 1 },
      { id: 1, kind: "context", text: "", newLine: 2 },
      { id: 2, kind: "context", text: "third", newLine: 3 },
    ]));
    expect(doc.attachment({ location: 0, length: doc.text.length })?.text).toBe("first\n\nthird");
  });

  it("round-trips sidebar preferences and decodes legacy defaults", () => {
    const project = makeProject({ name: "octo", rootPath: "/tmp/octo", threads: [makeThread({ workingDirectory: "/tmp/octo" })] });
    project.threads[0].agentSettings = { model: "fixture-model", reasoningEffort: "high" };
    project.isPinned = true; project.isCollapsed = true; project.threads[0].isPinned = true;
    const json = roundTrip(encodeArchive(makeArchive({ projects: [project] })));
    expect(decodeArchive(json).projects).toEqual([project]);
    const legacy = roundTrip(json);
    delete legacy.projects[0].isPinned; delete legacy.projects[0].isCollapsed;
    delete legacy.projects[0].threads[0].agentSettings; delete legacy.projects[0].threads[0].isPinned;
    const decoded = decodeArchive(legacy);
    expect(decoded.projects[0].threads[0].agentSettings).toEqual({});
    expect(decoded.projects[0].isPinned).toBe(false);
    expect(decoded.projects[0].isCollapsed).toBe(false);
    expect(decoded.projects[0].threads[0].isPinned).toBe(false);
    expect(decoded.projects[0].threads[0].id).toBe(project.threads[0].id);
  });

  it("orders pins first and moves the selection on removal", () => {
    const first = makeProject({ name: "first", rootPath: "/tmp/first", threads: [0, 1, 2].map((i) => makeThread({ title: `Thread ${i}`, workingDirectory: "/tmp/first" })) });
    first.threads[1].isPinned = true;
    const second = makeProject({ name: "second", rootPath: "/tmp/second" });
    second.isPinned = true;
    const archive = makeArchive({ projects: [first, second], selectedProjectID: first.id, selectedThreadID: first.threads[0].id });
    const [t0, t1, t2] = first.threads;
    expect(orderedProjects(archive).map((p) => p.id)).toEqual([second.id, first.id]);
    expect(orderedThreads(first).map((t) => t.id)).toEqual([t1.id, t2.id, t0.id]);
    removeThread(archive, t2.id, first.id);
    expect(archive.selectedThreadID).toBe(t0.id);
    removeThread(archive, t0.id, first.id);
    expect(archive.selectedThreadID).toBe(t1.id);
    removeProject(archive, first.id);
    expect(archive.selectedProjectID).toBe(second.id);
    expect(archive.selectedThreadID).toBeUndefined();
    removeProject(archive, second.id);
    expect(archive.selectedProjectID).toBeUndefined();
  });

  it("keeps newest-first threads, archive order and pins across reload", () => {
    for (const isChatCollection of [false, true]) {
      const project = makeProject({ name: "Conversations", rootPath: "/tmp", threads: [0, 1, 2, 3].map((i) => makeThread({ title: `Thread ${i}`, workingDirectory: "/tmp" })) });
      project.isChatCollection = isChatCollection;
      project.threads[0].isPinned = true;
      project.threads[2].isPinned = true;
      // Activity on an older thread must not move it within its pin group.
      project.threads[1].lastActivityAt = DISTANT_FUTURE;
      const originalIDs = project.threads.map((t) => t.id);
      const archive = decodeArchive(roundTrip(encodeArchive(makeArchive({ projects: [project] }))));
      expect(archive.projects[0].threads.map((t) => t.id)).toEqual(originalIDs);
      expect(orderedThreads(archive.projects[0]).map((t) => t.title)).toEqual(["Thread 2", "Thread 0", "Thread 3", "Thread 1"]);
      archive.projects[0].threads[0].isPinned = false;
      archive.projects[0].threads[2].isPinned = false;
      expect(orderedThreads(archive.projects[0]).map((t) => t.title)).toEqual(["Thread 3", "Thread 2", "Thread 1", "Thread 0"]);
      const newest = makeThread({ title: "Newest", workingDirectory: "/tmp" });
      archive.projects[0].threads.push(newest);
      expect(orderedThreads(archive.projects[0])[0].id).toBe(newest.id);
      archive.selectedThreadID = newest.id;
      removeThread(archive, newest.id, project.id);
      expect(archive.selectedThreadID).toBe(originalIDs[3]);
    }
  });

  it("round-trips image messages and decodes legacy ones", () => {
    const message = makeMessage("user", "Look at this", { images: [makeImage(Buffer.from([1, 2, 3]).toString("base64"))] });
    const encoded = roundTrip(encodeMessage(message));
    expect(encoded.images[0].pngData).toBe("AQID");
    expect(decodeMessage(encoded)).toEqual(message);
    delete encoded.images;
    expect(decodeMessage(encoded).images).toEqual([]);
  });
});
