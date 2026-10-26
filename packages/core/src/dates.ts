// The archive writes dates as seconds since 2001-01-01. Octo keeps dates as epoch milliseconds in
// memory and converts only at the archive boundary.
export const ARCHIVE_EPOCH_MS = 978_307_200_000;

export function fromArchiveDate(seconds: unknown): number {
  if (typeof seconds !== "number" || !Number.isFinite(seconds)) throw new TypeError("Expected a date");
  return ARCHIVE_EPOCH_MS + seconds * 1000;
}

export function toArchiveDate(ms: number): number {
  return (ms - ARCHIVE_EPOCH_MS) / 1000;
}

/** Year 1 and year 4001 in epoch milliseconds, used as ordering sentinels. */
export const DISTANT_PAST = -62_135_769_600_000;
export const DISTANT_FUTURE = 64_092_211_200_000;
