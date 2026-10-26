export interface Output { cursor: number; data: string }
/** Slices overlap at a snapshot boundary. A gap requires another main-process snapshot. */
export function nextOutput(cursor: number, event: Output): Output | undefined {
  if (event.cursor <= cursor) return { cursor, data: "" };
  const start = event.cursor - event.data.length;
  if (start > cursor) return;
  return { cursor: event.cursor, data: event.data.slice(Math.max(0, cursor - start)) };
}
