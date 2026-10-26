import { newID } from "./ids";
import { intersection, maxRange, NOT_FOUND, type TextRange } from "./range";
import { makeSnapshot, type ReviewSegment, type ReviewSnapshot, type CodeAttachment } from "./review";
import { sha256Hex } from "./sha256";

/** Exact editable source and UTF-16 coordinates. Gutters never become document text. */
export class SourceDocument {
  readonly text: string;
  readonly snapshot: ReviewSnapshot;
  readonly segments: ReviewSegment[];

  constructor(text: string, context: ReviewSnapshot) {
    this.text = text;
    const segments: ReviewSegment[] = [];
    let offset = 0;
    for (;;) {
      const newline = text.indexOf("\n", offset);
      const end = newline === -1 ? text.length : newline;
      const contentEnd = end > offset && text.charCodeAt(end - 1) === 13 ? end - 1 : end;
      const contentRange = { location: offset, length: contentEnd - offset };
      const line = { id: segments.length, kind: "context" as const, text: text.slice(offset, contentEnd), newLine: segments.length + 1 };
      const next = newline === -1 ? end : end + 1;
      segments.push({ displayRange: { location: offset, length: next - offset }, contentRange, line, file: 0 });
      offset = next;
      if (newline === -1 || offset > text.length) break;
    }
    this.segments = segments;
    const snapshot = makeSnapshot({
      projectID: context.projectID, workingDirectory: context.workingDirectory, path: context.path, scope: "file",
      baseRevision: context.baseRevision, lines: segments.map((s) => s.line),
    });
    snapshot.id = sha256Hex(snapshot.id + text);
    this.snapshot = snapshot;
  }

  lineIndexAt(offset: number): number | undefined {
    if (offset < 0 || offset > this.text.length) return undefined;
    let low = 0, high = this.segments.length;
    while (low < high) {
      const mid = (low + high) >> 1;
      if (this.segments[mid].displayRange.location <= offset) low = mid + 1; else high = mid;
    }
    return Math.max(0, low - 1);
  }

  attachmentRangeForLineAt(offset: number, selection: TextRange): TextRange | undefined {
    const index = this.lineIndexAt(offset);
    if (index === undefined) return undefined;
    const segment = this.segments[index];
    if (selection.location !== NOT_FOUND && selection.length > 0 && intersection(segment.displayRange, selection).length > 0) return selection;
    return segment.contentRange.length > 0 ? segment.contentRange : segment.displayRange;
  }

  attachment(r: TextRange): CodeAttachment | undefined {
    const length = this.text.length;
    if (r.location === NOT_FOUND || r.location < 0 || r.length <= 0 || r.location > length || r.length > length - r.location) return undefined;
    const first = this.lineIndexAt(r.location), last = this.lineIndexAt(maxRange(r) - 1);
    if (first === undefined || last === undefined) return undefined;
    const s = this.snapshot;
    return {
      id: newID(), projectID: s.projectID, workingDirectory: s.workingDirectory, path: s.path, snapshotID: s.id,
      baseRevision: s.baseRevision, scope: "file", newLines: [first + 1, last + 1], text: this.text.substr(r.location, r.length),
    };
  }
}
