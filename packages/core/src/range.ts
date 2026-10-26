/** A UTF-16 range. JavaScript string offsets are UTF-16 too, so they need no conversion. */
export interface TextRange {
  location: number;
  length: number;
}

/** NSNotFound. */
export const NOT_FOUND = -1;

export function range(location: number, length: number): TextRange {
  return { location, length };
}

export function maxRange(r: TextRange): number {
  return r.location + r.length;
}

export function locationInRange(location: number, r: TextRange): boolean {
  return r.location !== NOT_FOUND && location >= r.location && location - r.location < r.length;
}

export function intersection(a: TextRange, b: TextRange): TextRange {
  const start = Math.max(a.location, b.location);
  const end = Math.min(maxRange(a), maxRange(b));
  return end > start ? { location: start, length: end - start } : { location: 0, length: 0 };
}

export function rangesEqual(a: TextRange | undefined, b: TextRange | undefined): boolean {
  return a?.location === b?.location && a?.length === b?.length;
}

/** A closed line range, `lower...upper`. */
export type LineRange = [lower: number, upper: number];

export function lineSpan(values: number[]): LineRange | undefined {
  if (values.length === 0) return undefined;
  return [Math.min(...values), Math.max(...values)];
}
