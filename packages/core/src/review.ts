import { ZERO_ID } from "./ids";
import { newID } from "./ids";
import { intersection, lineSpan, locationInRange, maxRange, NOT_FOUND, type LineRange, type TextRange } from "./range";
import { sha256Hex } from "./sha256";

export type DiffScope = "working" | "staged" | "file";
export type DiffLayout = "stacked" | "sideBySide";
export type DiffSide = "before" | "after";
export type DiffLineKind = "context" | "addition" | "deletion" | "header";

export interface DiffLine {
  id: number;
  kind: DiffLineKind;
  text: string;
  oldLine?: number;
  newLine?: number;
}

export interface ReviewSnapshot {
  id: string;
  projectID: string;
  workingDirectory: string;
  path: string;
  scope: DiffScope;
  baseRevision: string;
  lines: DiffLine[];
  notice?: string;
}

export function makeSnapshot(fields: Omit<ReviewSnapshot, "id">): ReviewSnapshot {
  const content = fields.workingDirectory + fields.path + fields.scope + fields.baseRevision +
    fields.lines.map((l) => `${l.kind}:${l.oldLine ?? 0}:${l.newLine ?? 0}:${l.text}`).join("\n");
  return { ...fields, id: sha256Hex(content) };
}

/**
 * What a commit message draft describes: the index against HEAD. `patch` may be cut short on a
 * line boundary (`truncated`); `stat` always lists every staged file.
 */
export interface StagedChanges {
  stat: string;
  patch: string;
  truncated: boolean;
  /** Newest first, so a draft can follow the repository's style. */
  recentSubjects: string[];
}

export interface CodeAttachment {
  id: string;
  projectID: string;
  workingDirectory: string;
  path: string;
  snapshotID: string;
  baseRevision: string;
  scope: DiffScope;
  oldLines?: LineRange;
  newLines?: LineRange;
  text: string;
}

export function attachmentLabel(attachment: CodeAttachment): string {
  const r = attachment.newLines ?? attachment.oldLines;
  return attachment.path + (r ? `:${r[0]}–${r[1]}` : "");
}

export function attachmentPromptContext(a: CodeAttachment): string {
  const span = (r: LineRange | undefined) => (r ? `${r[0]}-${r[1]}` : "none");
  return [
    `<selected_code path="${a.path}" scope="${a.scope}">`,
    `Worktree: ${a.workingDirectory}`,
    `Snapshot: ${a.snapshotID}; base: ${a.baseRevision}`,
    `Original lines: ${span(a.oldLines)}`,
    `Changed lines: ${span(a.newLines)}`,
    "This is a captured selection; verify current file contents before editing.",
    a.text,
    "</selected_code>",
  ].join("\n");
}

export interface ReviewSegment {
  displayRange: TextRange;
  contentRange: TextRange;
  line: DiffLine;
  /** Index into `files`. */
  file: number;
}

/**
 * One file's part of the document. Multi-file documents give it a title row, which is not a
 * segment and so can never be attached.
 */
export interface FileSection {
  snapshot: ReviewSnapshot;
  headerRange?: TextRange;
  range: TextRange;
}

function linePrefix(line: DiffLine): string {
  const old = line.oldLine !== undefined ? String(line.oldLine) : "";
  const now = line.newLine !== undefined ? String(line.newLine) : "";
  const marker = line.kind === "addition" ? "+" : line.kind === "deletion" ? "−" : " ";
  return `${old.padStart(5)} ${now.padStart(5)} ${marker}  `;
}

/**
 * Maps UTF-16 text selection back to source lines; display gutters never enter prompts. A
 * multi-file document (every change in Changes) keeps each line's file, so a capture or a hunk
 * action always resolves to that file's own snapshot.
 */
export class ReviewDocument {
  text: string;
  segments: ReviewSegment[];
  /** The single file's snapshot; for a multi-file document, an identity covering every file. */
  snapshot: ReviewSnapshot;
  files: FileSection[];
  side?: DiffSide;

  private constructor(text: string, segments: ReviewSegment[], snapshot: ReviewSnapshot, files: FileSection[], side?: DiffSide) {
    this.text = text; this.segments = segments; this.snapshot = snapshot; this.files = files; this.side = side;
  }

  get isMultiFile(): boolean {
    return this.files.length !== 1 || this.files[0]?.headerRange !== undefined;
  }

  static fromSource(source: { text: string; segments: ReviewSegment[]; snapshot: ReviewSnapshot }): ReviewDocument {
    return new ReviewDocument(source.text, source.segments, source.snapshot,
      [{ snapshot: source.snapshot, range: { location: 0, length: source.text.length } }]);
  }

  static fromSnapshot(snapshot: ReviewSnapshot): ReviewDocument {
    let text = "";
    const segments: ReviewSegment[] = [];
    for (const line of snapshot.lines) {
      const start = text.length;
      text += linePrefix(line);
      const content = { location: text.length, length: line.text.length };
      segments.push({ displayRange: { location: start, length: maxRange(content) + 1 - start }, contentRange: content, line, file: 0 });
      text += line.text + "\n";
    }
    return new ReviewDocument(text, segments, snapshot, [{ snapshot, range: { location: 0, length: text.length } }]);
  }

  /**
   * Every file in order, each under a title row (path and scope) and separated by a blank row.
   * Files without text lines show their notice, such as a binary change, as a note row.
   */
  static fromFiles(snapshots: ReviewSnapshot[]): ReviewDocument {
    let text = "";
    const segments: ReviewSegment[] = [];
    const files: FileSection[] = [];
    snapshots.forEach((file, index) => {
      const start = text.length;
      if (index > 0) text += "\n";
      const headerStart = text.length;
      const title = `${file.path}  ·  ${file.scope === "staged" ? "Staged" : "Unstaged"}`;
      text += title + "\n";
      const header = { location: headerStart, length: title.length + 1 };
      let lines = file.lines;
      if (lines.length === 0 && file.notice !== undefined) lines = [{ id: -1, kind: "header", text: file.notice }];
      for (const line of lines) {
        const lineStart = text.length;
        text += linePrefix(line);
        const content = { location: text.length, length: line.text.length };
        segments.push({ displayRange: { location: lineStart, length: maxRange(content) + 1 - lineStart }, contentRange: content, line, file: index });
        text += line.text + "\n";
      }
      files.push({ snapshot: file, headerRange: header, range: { location: start, length: text.length - start } });
    });
    const first = snapshots[0];
    const snapshot = makeSnapshot({
      projectID: first?.projectID ?? ZERO_ID, workingDirectory: first?.workingDirectory ?? "", path: "",
      scope: first?.scope ?? "working", baseRevision: snapshots.map((s) => s.id).join(":"), lines: [],
    });
    return new ReviewDocument(text, segments, snapshot, files);
  }

  /**
   * Each change block is paired in source order. Missing counterparts occupy a display row but
   * have no source segment, so padding can never be attached.
   */
  static sideBySide(snapshot: ReviewSnapshot): { before: ReviewDocument; after: ReviewDocument } {
    const before: (DiffLine | undefined)[] = [], after: (DiffLine | undefined)[] = [];
    let deletions: DiffLine[] = [], additions: DiffLine[] = [];
    let lastChange: DiffSide | undefined;
    const flush = () => {
      for (let row = 0; row < Math.max(deletions.length, additions.length); row++) {
        before.push(deletions[row]);
        after.push(additions[row]);
      }
      deletions = []; additions = [];
    };
    for (const line of snapshot.lines) {
      if (line.kind === "deletion") { deletions.push(line); lastChange = "before"; }
      else if (line.kind === "addition") { additions.push(line); lastChange = "after"; }
      else if (line.kind === "header" && line.text.startsWith("\\") && lastChange !== undefined) {
        // Git's missing-newline note belongs to the preceding version.
        (lastChange === "before" ? deletions : additions).push(line);
      } else {
        flush(); lastChange = undefined; before.push(line); after.push(line);
      }
    }
    flush();
    return { before: ReviewDocument.rows(snapshot, before, "before"), after: ReviewDocument.rows(snapshot, after, "after") };
  }

  private static rows(snapshot: ReviewSnapshot, rows: (DiffLine | undefined)[], side: DiffSide): ReviewDocument {
    let text = "";
    const segments: ReviewSegment[] = [];
    for (const line of rows) {
      if (!line) { text += "\n"; continue; }
      const number = side === "before" ? line.oldLine : line.newLine;
      const marker = line.kind === "addition" ? "+" : line.kind === "deletion" ? "−" : " ";
      const prefix = `${(number !== undefined ? String(number) : "").padStart(5)} ${marker}  `;
      const offset = text.length;
      const content = { location: offset + prefix.length, length: line.text.length };
      segments.push({ displayRange: { location: offset, length: prefix.length + content.length + 1 }, contentRange: content, line, file: 0 });
      text += prefix + line.text + "\n";
    }
    return new ReviewDocument(text, segments, snapshot, [{ snapshot, range: { location: 0, length: text.length } }], side);
  }

  /** The file whose section contains a display offset, including its title row. */
  fileAt(offset: number): number | undefined {
    let lower = 0, upper = this.files.length;
    while (lower < upper) {
      const middle = (lower + upper) >> 1;
      if (maxRange(this.files[middle].range) <= offset) lower = middle + 1; else upper = middle;
    }
    return lower < this.files.length && locationInRange(offset, this.files[lower].range) ? lower : undefined;
  }

  /**
   * The segment index of the `@@` header starting the hunk at a display offset, within the same
   * file. Title rows, notes and the blank row between files belong to no hunk.
   */
  hunkHeaderAt(offset: number): number | undefined {
    const file = this.fileAt(offset);
    if (file === undefined) return undefined;
    const section = this.files[file];
    const header = section.headerRange ? maxRange(section.headerRange) : section.range.location;
    if (offset < header) return undefined;
    let lower = 0, upper = this.segments.length;
    while (lower < upper) {
      const middle = (lower + upper) >> 1;
      if (this.segments[middle].displayRange.location <= offset) lower = middle + 1; else upper = middle;
    }
    for (let index = lower - 1; index >= 0 && this.segments[index].file === file; index--) {
      const line = this.segments[index].line;
      if (line.kind === "header" && line.text.startsWith("@@")) return index;
    }
    return undefined;
  }

  /**
   * The gutter action uses an existing selection only when hovering one of its source lines.
   * Otherwise it captures the whole hovered line, including empty source lines.
   */
  attachmentRangeForLineAt(offset: number, selection: TextRange): TextRange | undefined {
    if (offset < 0 || offset >= this.text.length) return undefined;
    let lower = 0, upper = this.segments.length;
    while (lower < upper) {
      const middle = (lower + upper) >> 1;
      if (maxRange(this.segments[middle].displayRange) <= offset) lower = middle + 1; else upper = middle;
    }
    const segment = this.segments[lower];
    if (!segment || !locationInRange(offset, segment.displayRange) || segment.line.kind === "header") return undefined;
    const source = { location: segment.contentRange.location, length: Math.max(1, segment.contentRange.length) };
    if (selection.location !== NOT_FOUND && selection.length > 0 &&
        intersection(source, selection).length > 0 && this.attachment(selection) !== undefined) {
      return selection;
    }
    return source;
  }

  /** A selection that crosses into another file captures only the file where it starts. */
  attachment(r: TextRange): CodeAttachment | undefined {
    if (r.location === NOT_FOUND || r.location < 0 || r.length <= 0 || maxRange(r) > this.text.length) return undefined;
    const chunks: string[] = [], old: number[] = [], now: number[] = [];
    let file: number | undefined;
    for (const segment of this.segments) {
      if (segment.line.kind === "header") continue;
      if (file !== undefined && segment.file !== file) continue;
      const overlap = intersection(r, segment.contentRange);
      const selectedEmptyLine = segment.contentRange.length === 0 && locationInRange(segment.contentRange.location, r);
      if (overlap.length <= 0 && !selectedEmptyLine) continue;
      file = segment.file;
      chunks.push(selectedEmptyLine ? "" : this.text.substr(overlap.location, overlap.length));
      if (segment.line.oldLine !== undefined) old.push(segment.line.oldLine);
      if (segment.line.newLine !== undefined) now.push(segment.line.newLine);
    }
    if (chunks.length === 0) return undefined;
    const snapshot = (file !== undefined ? this.files[file]?.snapshot : undefined) ?? this.snapshot;
    return {
      id: newID(), projectID: snapshot.projectID, workingDirectory: snapshot.workingDirectory, path: snapshot.path,
      snapshotID: snapshot.id, baseRevision: snapshot.baseRevision, scope: snapshot.scope,
      oldLines: lineSpan(old), newLines: lineSpan(now), text: chunks.join("\n"),
    };
  }
}
