import { newID, SourceDocument, type CodeAttachment, type ReviewSnapshot } from "@octo/core";
import type { DiffLineAnnotation, SelectedLineRange } from "@pierre/diffs";

/** Pierre receives a display-only patch; captures always refer to the original immutable snapshot. */
export function snapshotPatch(snapshot: ReviewSnapshot): string {
  if (!snapshot.lines.length) return "";
  const header = snapshot.lines.some((line) => line.kind === "header" && line.text.startsWith("@@"));
  const path = (prefix: string) => JSON.stringify(prefix + snapshot.path);
  const body = snapshot.lines.map((line) => (line.kind === "header" ? "" : line.kind === "addition" ? "+" : line.kind === "deletion" ? "-" : " ") + line.text).join("\n");
  return `diff --git ${path("a/")} ${path("b/")}\n--- ${header ? path("a/") : "/dev/null"}\n+++ ${path("b/")}\n${header ? "" : `@@ -0,0 +1,${snapshot.lines.length} @@\n`}${body}\n`;
}
export function captureDiff(snapshot: ReviewSnapshot, range: SelectedLineRange): CodeAttachment | undefined {
  const lineNumber = (side: string | undefined, line: ReviewSnapshot["lines"][number]) => side === "deletions" ? line.oldLine : line.newLine;
  const start = snapshot.lines.findIndex((line) => lineNumber(range.side, line) === range.start);
  const end = snapshot.lines.findIndex((line) => lineNumber(range.endSide ?? range.side, line) === range.end);
  if (start < 0 || end < 0) return;
  const sameSide = !range.endSide || range.endSide === range.side;
  const lines = snapshot.lines.slice(Math.min(start, end), Math.max(start, end) + 1).filter((line) => line.kind !== "header" && (!sameSide || lineNumber(range.side, line) !== undefined));
  if (!lines.length) return;
  const span = (values: (number | undefined)[]): [number, number] | undefined => { const n = values.filter((v): v is number => v !== undefined); return n.length ? [Math.min(...n), Math.max(...n)] : undefined; };
  return { id: newID(), projectID: snapshot.projectID, workingDirectory: snapshot.workingDirectory, path: snapshot.path,
    snapshotID: snapshot.id, baseRevision: snapshot.baseRevision, scope: snapshot.scope,
    oldLines: sameSide && range.side !== "deletions" ? undefined : span(lines.map((l) => l.oldLine)),
    newLines: sameSide && range.side === "deletions" ? undefined : span(lines.map((l) => l.newLine)), text: lines.map((l) => l.text).join("\n") };
}
export function captureFile(text: string, context: ReviewSnapshot, range: SelectedLineRange): CodeAttachment | undefined {
  const doc = new SourceDocument(text, context);
  const first = doc.segments[Math.min(range.start, range.end) - 1], last = doc.segments[Math.max(range.start, range.end) - 1];
  if (!first || !last) return;
  return doc.attachment({ location: first.contentRange.location, length: last.contentRange.location + last.contentRange.length - first.contentRange.location });
}
export function hunkIDs(snapshot: ReviewSnapshot): number[] { return snapshot.lines.filter((l) => l.kind === "header" && l.text.startsWith("@@")).map((l) => l.id); }

export interface HunkAnnotation { hunk: number; index: number }

/**
 * Where each hunk's action goes: above its first line. The first hunk's action is a file-level
 * annotation; each later one follows the last line of the hunk before it.
 */
export function hunkAnnotations(snapshot: ReviewSnapshot): DiffLineAnnotation<HunkAnnotation>[] {
  const result: DiffLineAnnotation<HunkAnnotation>[] = [];
  let previous: { side: "additions" | "deletions"; line: number } | undefined;
  for (const line of snapshot.lines) {
    if (line.kind === "header" && line.text.startsWith("@@")) {
      result.push({ side: previous?.side ?? "additions", lineNumber: previous?.line ?? 0, metadata: { hunk: line.id, index: result.length } });
    } else if (line.newLine !== undefined) previous = { side: "additions", line: line.newLine };
    else if (line.oldLine !== undefined) previous = { side: "deletions", line: line.oldLine };
  }
  return result;
}

