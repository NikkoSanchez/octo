import type { ConversationUsage, TokenCounts } from "@octo/core";
import { AgentToolDetails } from "./toolDetails";
import type { AgentUsage, AgentUsageWindow } from "./types";
import type { JSONObject } from "./jsonLine";

const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);

const KNOWN: Record<string, { name: string; minutes?: number }> = {
  five_hour: { name: "Session (5-hour)", minutes: 300 },
  seven_day: { name: "Weekly · all models", minutes: 10_080 },
  seven_day_opus: { name: "Weekly · Opus", minutes: 10_080 },
  seven_day_sonnet: { name: "Weekly · Sonnet", minutes: 10_080 },
  seven_day_overage_included: { name: "Weekly · including extra usage", minutes: 10_080 },
  overage: { name: "Extra usage" },
};
const ORDER = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included", "overage"];

/**
 * Claude Code 2.1.302 SDK `rate_limit_event`: status/rateLimitType/utilization/resetsAt describe the
 * limiting window. `unifiedWindows` is marked internal upstream, so it is read only when present.
 * Utilization is a fraction of the window; values past 1 are possible. Absent fields stay unknown.
 */
export function decodeClaudeRateLimit(info: JSONObject, at = Date.now()): AgentUsage | undefined {
  const window = (type: string, utilization: unknown, resetsAt: unknown, limited: boolean): AgentUsageWindow => {
    const percent = typeof utilization === "number" ? utilization * 100 : undefined;
    const known = KNOWN[type];
    const result: AgentUsageWindow = { id: type, name: known?.name ?? AgentToolDetails.text(type, 60), isLimited: limited };
    if (percent !== undefined && Number.isFinite(percent) && percent >= 0) result.usedPercent = percent;
    if (known?.minutes !== undefined) result.durationMinutes = known.minutes;
    if (typeof resetsAt === "number") result.resetsAt = resetsAt * 1000;
    return result;
  };
  const windows = new Map<string, AgentUsageWindow>();
  if (isObject(info.unifiedWindows)) {
    for (const [type, value] of Object.entries(info.unifiedWindows)) {
      if (!isObject(value)) continue;
      windows.set(type, window(type, value.utilization, value.resetsAt, false));
    }
  }
  if (typeof info.rateLimitType === "string") {
    const type = info.rateLimitType;
    const current = window(type, info.utilization, info.resetsAt, info.status === "rejected");
    const previous = windows.get(type);
    if (previous) {
      if (current.usedPercent === undefined && previous.usedPercent !== undefined) current.usedPercent = previous.usedPercent;
      if (current.resetsAt === undefined && previous.resetsAt !== undefined) current.resetsAt = previous.resetsAt;
    }
    windows.set(type, current);
  }
  if (windows.size === 0) return undefined;
  const rank = (id: string) => (ORDER.indexOf(id) === -1 ? ORDER.length : ORDER.indexOf(id));
  const sorted = [...windows.values()].sort((a, b) => rank(a.id) - rank(b.id) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { buckets: [{ id: "claude", title: "Claude subscription", windows: sorted }], fetchedAt: at };
}

/**
 * Claude Code 2.1.302 `get_context_usage` control response, the accounting behind `/context`:
 * `totalTokens` is occupied context, `maxTokens` the model window, `autoCompactThreshold` the
 * automatic-compaction point and `apiUsage` the last API response, whose `input_tokens` excludes cache
 * reads and writes. Undefined before the session has a response.
 */
export function decodeClaudeContextUsage(response: JSONObject, session: TokenCounts | undefined, at = Date.now()): ConversationUsage | undefined {
  const count = (value: unknown): number | undefined =>
    typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
  // Untrusted counts saturate instead of overflowing past exact integers.
  const sum = (...values: number[]) => Math.min(Number.MAX_SAFE_INTEGER, values.reduce((a, b) => a + b, 0));
  const occupied = count(response.totalTokens);
  const api = isObject(response.apiUsage) ? response.apiUsage : undefined;
  const uncached = count(api?.input_tokens), output = count(api?.output_tokens);
  if (occupied === undefined || !api || uncached === undefined || output === undefined) return undefined;
  const cached = count(api.cache_read_input_tokens) ?? 0, written = count(api.cache_creation_input_tokens) ?? 0;
  const input = sum(uncached, cached, written);
  const thresholdValue = count(response.autoCompactThreshold);
  const threshold = response.isAutoCompactEnabled === true && thresholdValue !== undefined && thresholdValue > 0 ? thresholdValue : undefined;
  const max = count(response.maxTokens);
  return {
    latest: { total: sum(input, output), input, cachedInput: cached, cacheWriteInput: written, output },
    ...(session ? { session } : {}),
    ...(max !== undefined && max > 0 ? { contextWindow: max } : {}),
    contextTokens: occupied,
    ...(threshold !== undefined ? { autoCompactThreshold: threshold } : {}),
    updatedAt: at,
  };
}
