/** IDs are uppercase UUID strings, the form the archive stores. */
export function newID(): string {
  return crypto.randomUUID().toUpperCase();
}

export const ZERO_ID = "00000000-0000-0000-0000-000000000000";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUUID(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** Normalizes a decoded UUID so comparisons never depend on letter case. */
export function normalizeUUID(value: unknown): string {
  if (!isUUID(value)) throw new TypeError(`Expected a UUID, got ${JSON.stringify(value)}`);
  return value.toUpperCase();
}
