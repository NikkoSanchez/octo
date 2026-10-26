import { HARNESS_IDS, type HarnessID } from "@octo/core";

/** Token counts recorded by provider CLIs in their local session logs, bucketed by hour. */
export interface UsageRecord {
  provider: HarnessID;
  model: string;
  session: string;
  /** Epoch milliseconds at the start of the hour. */
  hour: number;
  /** Input served from the prompt cache. */
  cachedInput: number;
  /** Input written to the prompt cache (billed as input, not served from cache). */
  cacheWrite: number;
  /** Input neither read from nor written to the cache. */
  uncachedInput: number;
  /** Output including reasoning. */
  output: number;
}

export function makeUsageRecord(fields: Pick<UsageRecord, "provider" | "model" | "session" | "hour"> & Partial<UsageRecord>): UsageRecord {
  return { cachedInput: 0, cacheWrite: 0, uncachedInput: 0, output: 0, ...fields };
}

export const recordTotal = (r: UsageRecord) => r.cachedInput + r.cacheWrite + r.uncachedInput + r.output;
export const HOUR = 3_600_000;
export const hourOf = (ms: number) => Math.floor(ms / HOUR) * HOUR;

export interface UsageSummaryProvider { id: HarnessID; tokens: number; sessions: number }
export interface UsageSummaryPoint { start: number; provider: HarnessID; tokens: number }
export interface UsageSummaryRow { id: string; title: string; provider?: HarnessID; date?: number; tokens: number; share: number }

export interface UsageSummary {
  interval: { start: number; end: number };
  hourly: boolean;
  total: number; sessions: number; cachedInput: number; cacheWrite: number; uncachedInput: number; output: number;
  providers: UsageSummaryProvider[];
  series: UsageSummaryPoint[];
  models: UsageSummaryRow[];
  days: UsageSummaryRow[];
}

export interface CalendarFunctions {
  startOfDay(ms: number): number;
  addDay(ms: number): number;
}

export const localCalendar: CalendarFunctions = {
  startOfDay(ms) { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); },
  addDay(ms) { const d = new Date(ms); d.setDate(d.getDate() + 1); return d.getTime(); },
};

/** Aggregates for one time range. Pure so it can be tested without files. */
export function summarizeUsage(allRecords: UsageRecord[], interval: { start: number; end: number }, calendar: CalendarFunctions = localCalendar): UsageSummary {
  const hourly = interval.end - interval.start <= 48 * HOUR;
  const first = hourOf(interval.start);
  const records = allRecords.filter((r) => r.hour >= first && r.hour <= interval.end);
  const summary: UsageSummary = {
    interval, hourly, total: 0, sessions: 0, cachedInput: 0, cacheWrite: 0, uncachedInput: 0, output: 0,
    providers: [], series: [], models: [], days: [],
  };
  const providerTokens = new Map<HarnessID, number>(), providerSessions = new Map<HarnessID, Set<string>>();
  const modelTokens = new Map<string, [HarnessID, number]>(), bucketTokens = new Map<number, Map<HarnessID, number>>(), dayTokens = new Map<number, number>();
  const bucket = (ms: number) => (hourly ? hourOf(ms) : calendar.startOfDay(ms));
  for (const record of records) {
    const total = recordTotal(record);
    summary.total += total; summary.cachedInput += record.cachedInput; summary.cacheWrite += record.cacheWrite;
    summary.uncachedInput += record.uncachedInput; summary.output += record.output;
    providerTokens.set(record.provider, (providerTokens.get(record.provider) ?? 0) + total);
    if (!providerSessions.has(record.provider)) providerSessions.set(record.provider, new Set());
    providerSessions.get(record.provider)!.add(record.session);
    const modelKey = record.provider + "\0" + record.model;
    modelTokens.set(modelKey, [record.provider, (modelTokens.get(modelKey)?.[1] ?? 0) + total]);
    const b = bucket(record.hour);
    if (!bucketTokens.has(b)) bucketTokens.set(b, new Map());
    bucketTokens.get(b)!.set(record.provider, (bucketTokens.get(b)!.get(record.provider) ?? 0) + total);
    const day = calendar.startOfDay(record.hour);
    dayTokens.set(day, (dayTokens.get(day) ?? 0) + total);
  }
  summary.sessions = [...providerSessions.values()].reduce((n, s) => n + s.size, 0);
  const active = HARNESS_IDS.filter((id) => providerTokens.has(id));
  summary.providers = active.map((id) => ({ id, tokens: providerTokens.get(id)!, sessions: providerSessions.get(id)?.size ?? 0 }))
    .sort((a, b) => b.tokens - a.tokens);
  // Every bucket in the range is present so empty periods draw as zero rather than interpolating.
  const starts: number[] = [];
  for (let cursor = bucket(interval.start); cursor <= interval.end; cursor = hourly ? cursor + HOUR : calendar.addDay(cursor)) starts.push(cursor);
  summary.series = active.flatMap((provider) => starts.map((start) => ({ start, provider, tokens: bucketTokens.get(start)?.get(provider) ?? 0 })));
  const denominator = Math.max(summary.total, 1);
  summary.models = [...modelTokens].map(([key, [provider, tokens]]) => ({
    id: key, title: key.split("\0").slice(1).join("\0"), provider, tokens, share: tokens / denominator,
  })).sort((a, b) => b.tokens - a.tokens || (a.title < b.title ? -1 : a.title > b.title ? 1 : 0));
  summary.days = [...dayTokens].map(([day, tokens]) => ({ id: String(day), title: "", date: day, tokens, share: tokens / denominator }))
    .sort((a, b) => b.date! - a.date!);
  return summary;
}
