import { maxRange, type TextRange } from "./range";

/**
 * Markdown list editing for the plain-text composer: Shift-Return continues a list or quote, and
 * Tab / Shift-Tab nest list items. Ranges are UTF-16.
 */
export interface ListEdit {
  /** The characters to replace and their replacement. */
  range: TextRange;
  replacement: string;
  selection: TextRange;
}

type Marker = { kind: "bullet"; char: string } | { kind: "ordered"; number: number; delimiter: string } | { kind: "quote" };

/** One line's list or quote prefix: indentation, marker and the spaces after it. */
class Line {
  indent: number;
  marker: Marker;
  spacing: number;
  /** A task item's `[ ]` or `[x]` and its following space, which belongs to the content. */
  checkbox: boolean;

  private constructor(indent: number, marker: Marker, spacing: number, checkbox: boolean) {
    this.indent = indent; this.marker = marker; this.spacing = spacing; this.checkbox = checkbox;
  }

  static parse(text: string): Line | undefined {
    const chars = Array.from(text);
    let i = 0;
    while (i < chars.length && chars[i] === " ") i++;
    const indent = i;
    if (i >= chars.length) return undefined;
    let marker: Marker;
    if ("-*+".includes(chars[i])) { marker = { kind: "bullet", char: chars[i] }; i++; }
    else if (chars[i] === ">") { marker = { kind: "quote" }; i++; }
    else {
      let digits = "";
      while (i < chars.length && /^[0-9]$/.test(chars[i]) && digits.length < 9) { digits += chars[i]; i++; }
      if (!digits || i >= chars.length || (chars[i] !== "." && chars[i] !== ")")) return undefined;
      marker = { kind: "ordered", number: Number(digits), delimiter: chars[i] };
      i++;
    }
    // A marker needs a following space (a bare quote marker is allowed), else `-1` or `2.5` would count.
    let spaces = 0;
    while (i < chars.length && chars[i] === " ") { spaces++; i++; }
    if (spaces === 0 && !(marker.kind === "quote" && i === chars.length)) return undefined;
    const checkbox = marker.kind !== "quote" && chars.length >= i + 3 &&
      chars[i] === "[" && " xX".includes(chars[i + 1]) && chars[i + 2] === "]" &&
      (chars.length === i + 3 || chars[i + 3] === " ");
    return new Line(indent, marker, spaces, checkbox);
  }

  get markerText(): string {
    switch (this.marker.kind) {
      case "bullet": return this.marker.char;
      case "ordered": return `${this.marker.number}${this.marker.delimiter}`;
      case "quote": return ">";
    }
  }
  /** UTF-16 units before the content. */
  get prefixLength(): number { return this.indent + this.markerText.length + this.spacing; }
  get isListItem(): boolean { return this.marker.kind !== "quote"; }

  withIndent(indent: number, number?: number): string {
    let markerText = this.markerText;
    if (this.marker.kind === "ordered" && number !== undefined) markerText = `${number}${this.marker.delimiter}`;
    return " ".repeat(indent) + markerText + " ".repeat(this.spacing);
  }
}

const isBreak = (code: number) => code === 10 || code === 13;

/** Whole lines containing `r`, including their terminators. */
function lineRange(text: string, r: TextRange): TextRange {
  let start = r.location;
  while (start > 0 && !isBreak(text.charCodeAt(start - 1))) start--;
  let end = r.length > 0 ? Math.max(r.location, maxRange(r) - 1) : r.location;
  if (end < text.length && isBreak(text.charCodeAt(end)) && r.length > 0 && end >= r.location) {
    // The last selected character is itself a terminator: that line ends here.
  } else {
    while (end < text.length && !isBreak(text.charCodeAt(end))) end++;
  }
  if (end < text.length) {
    if (text.charCodeAt(end) === 13 && text.charCodeAt(end + 1) === 10) end += 2; else end += 1;
  }
  return { location: start, length: end - start };
}

/** Lines (content ranges, no terminators) intersecting `[0, end)`, as enumerateSubstrings(.byLines). */
function linesBefore(text: string, end: number): { start: number; content: string }[] {
  const lines: { start: number; content: string }[] = [];
  let start = 0;
  while (start < end) {
    let stop = start;
    while (stop < text.length && !isBreak(text.charCodeAt(stop))) stop++;
    lines.push({ start, content: text.slice(start, stop) });
    if (stop >= text.length) break;
    start = text.charCodeAt(stop) === 13 && text.charCodeAt(stop + 1) === 10 ? stop + 2 : stop + 1;
  }
  return lines;
}

function lineContent(text: string, r: TextRange): { text: string; length: number } {
  let length = r.length;
  while (length > 0 && isBreak(text.charCodeAt(r.location + length - 1))) length--;
  return { text: text.substr(r.location, length), length };
}

function replace(text: string, r: TextRange, replacement: string): string {
  return text.slice(0, r.location) + replacement + text.slice(maxRange(r));
}

export const MarkdownListEditing = {
  /**
   * Shift-Return at a caret after a list or quote marker. An empty item ends the list: nested
   * items step out one level, top-level ones lose their marker. Undefined inserts a plain newline.
   */
  newline(text: string, selection: TextRange): ListEdit | undefined {
    if (selection.length !== 0) return undefined;
    const lines = lineRange(text, { location: selection.location, length: 0 });
    const content = lineContent(text, lines);
    const line = Line.parse(content.text);
    if (!line || selection.location - lines.location < line.prefixLength) return undefined;
    const body = content.text.slice(line.prefixLength);
    if ((line.checkbox ? body.slice(3) : body).trim() === "") {
      if (line.isListItem && line.indent > 0) {
        const outdented = MarkdownListEditing.outdent(text, selection);
        if (outdented) return outdented;
      }
      return { range: { location: lines.location, length: content.length }, replacement: "", selection: { location: lines.location, length: 0 } };
    }
    let next = " ".repeat(line.indent);
    if (line.marker.kind === "ordered") next += `${line.marker.number + 1}${line.marker.delimiter}`;
    else next += line.markerText;
    next += " ".repeat(Math.max(1, line.spacing)) + (line.checkbox ? "[ ] " : "");
    const inserted = "\n" + next;
    return { range: selection, replacement: inserted, selection: { location: selection.location + inserted.length, length: 0 } };
  },

  /**
   * Tab: nests each selected list item under the item above it at its level, aligning with that
   * item's content as CommonMark requires; ordered items restart at 1. Undefined when no line changes.
   */
  indent(text: string, selection: TextRange): ListEdit | undefined {
    return reindent(text, selection, (lines, index, line) => {
      // The nearest earlier item at this level becomes the parent; stop at a blank or non-list line.
      let j = index - 1;
      let parent: Line | undefined, sibling: Line | undefined;
      for (; j >= 0; j--) {
        const candidate = Line.parse(lines[j]);
        if (!candidate || !candidate.isListItem) break;
        if (candidate.indent === line.indent) { parent = candidate; break; }
        if (candidate.indent < line.indent) break;
      }
      if (!parent) return undefined;
      const level = parent.prefixLength;
      for (let k = index - 1; k > j; k--) {
        const candidate = Line.parse(lines[k]);
        if (candidate && candidate.indent === level) { sibling = candidate; break; }
      }
      if (sibling?.marker.kind === "ordered") return line.withIndent(level, sibling.marker.number + 1);
      return line.withIndent(level, 1);
    });
  },

  /** Shift-Tab: moves each selected nested item out to its parent's level, numbered after it. */
  outdent(text: string, selection: TextRange): ListEdit | undefined {
    return reindent(text, selection, (lines, index, line) => {
      if (line.indent <= 0) return undefined;
      for (let j = index - 1; j >= 0; j--) {
        const candidate = Line.parse(lines[j]);
        if (!candidate || !candidate.isListItem) break;
        if (candidate.indent < line.indent) {
          if (candidate.marker.kind === "ordered") return line.withIndent(candidate.indent, candidate.marker.number + 1);
          return line.withIndent(candidate.indent);
        }
      }
      return line.withIndent(0);
    });
  },

  /** Whether the caret's line, or any selected line, is a list item, so Tab belongs to the list. */
  isInList(text: string, selection: TextRange): boolean {
    const span = lineRange(text, selection);
    return linesBefore(text, maxRange(span))
      .filter((l) => l.start >= span.location)
      .some((l) => Line.parse(l.content)?.isListItem === true);
  },

  apply(text: string, edit: ListEdit): string {
    return replace(text, edit.range, edit.replacement);
  },
};

/**
 * Rewrites the prefix of each selected list line. `prefix` sees the lines as already rewritten
 * above it and returns the new prefix, or undefined to leave the line alone.
 */
function reindent(text: string, selection: TextRange,
                  prefix: (lines: string[], index: number, line: Line) => string | undefined): ListEdit | undefined {
  const span = lineRange(text, selection);
  // Every line up to the selection's end, so parents above the selection are visible.
  const found = linesBefore(text, maxRange(span));
  const lines = found.map((l) => l.content), starts = found.map((l) => l.start);
  if (maxRange(span) === text.length && (text.length === 0 || isBreak(text.charCodeAt(text.length - 1)))) {
    lines.push(""); starts.push(text.length);
  }
  const lastIndexWhere = (predicate: (start: number) => boolean) => {
    for (let i = starts.length - 1; i >= 0; i--) if (predicate(starts[i])) return i;
    return -1;
  };
  const first = lastIndexWhere((s) => s <= span.location);
  if (first === -1) return undefined;
  const lastFound = lastIndexWhere((s) => s <= Math.max(span.location, maxRange(selection) - (selection.length > 0 ? 1 : 0)));
  const last = lastFound === -1 ? first : lastFound;
  const originals = [...lines];
  let changed = false;
  let caret = selection;
  for (let index = first; index <= last; index++) {
    const line = Line.parse(lines[index]);
    if (!line || !line.isListItem) continue;
    const newPrefix = prefix(lines, index, line);
    if (newPrefix === undefined) continue;
    const old = lines[index];
    lines[index] = newPrefix + old.slice(line.prefixLength);
    const delta = newPrefix.length - line.prefixLength;
    if (delta !== 0 || newPrefix !== old.slice(0, line.prefixLength)) changed = true;
    if (selection.length === 0) {
      const offset = selection.location - starts[index];
      caret = { location: starts[index] + Math.max(newPrefix.length, offset + delta), length: 0 };
    }
  }
  if (!changed) return undefined;
  // Replace the lines' contents only; their line breaks stay where they are.
  const start = starts[first];
  const end = starts[last] + originals[last].length;
  const replacement = lines.slice(first, last + 1).join("\n");
  const newSelection = selection.length === 0 ? caret : { location: start, length: replacement.length };
  return { range: { location: start, length: end - start }, replacement, selection: newSelection };
}
