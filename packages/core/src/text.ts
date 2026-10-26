// String helpers shared by search, previews and the composer. Offsets are UTF-16, as in JavaScript
// strings.

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** User-perceived characters (grapheme clusters). */
export function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), (segment) => segment.segment);
}

export function graphemeCount(text: string): number {
  let count = 0;
  for (const _ of segmenter.segment(text)) count++;
  return count;
}

export function isBlank(text: string): boolean {
  return text.trim().length === 0;
}

/**
 * Case-, diacritic- and width-insensitive folding with a map back to the original, as
 * Foundation's `[.caseInsensitive, .diacriticInsensitive, .widthInsensitive]` compares.
 * `starts[i]`/`ends[i]` give the original UTF-16 range that produced folded unit `i`.
 */
export interface FoldedText {
  text: string;
  starts: number[];
  ends: number[];
}

export function fold(text: string): FoldedText {
  let out = "";
  const starts: number[] = [];
  const ends: number[] = [];
  let index = 0;
  for (const point of text) {
    const folded = point.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
    for (let i = 0; i < folded.length; i++) {
      starts.push(index);
      ends.push(index + point.length);
    }
    out += folded;
    index += point.length;
  }
  return { text: out, starts, ends };
}

export function foldQuery(text: string): string {
  return fold(text).text;
}

/** The original range of folded units `[start, end)`. */
export function unfoldRange(folded: FoldedText, start: number, end: number): [number, number] {
  if (end <= start) {
    const at = start < folded.starts.length ? folded.starts[start] : (folded.ends[folded.ends.length - 1] ?? 0);
    return [at, at];
  }
  return [folded.starts[start], folded.ends[end - 1]];
}

export function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
