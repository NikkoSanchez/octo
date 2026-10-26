import type { ConversationUsage, TokenCounts } from "@octo/core";
import { ProcessFailure } from "@octo/core/node";
import type { AgentModel, AgentUsage, AgentUsageBucket, AgentUsageWindow, ReasoningOption } from "./types";
import type { JSONObject } from "./jsonLine";

const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const malformed = (what: string) => new ProcessFailure("exited", `Codex returned a malformed ${what}.`);

function optionalNumber(value: unknown, what: string): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value)) throw malformed(what);
  return value;
}
function optionalInt(value: unknown, what: string): number | undefined {
  const n = optionalNumber(value, what);
  if (n !== undefined && !Number.isInteger(n)) throw malformed(what);
  return n;
}
function optionalString(value: unknown, what: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw malformed(what);
  return value;
}

/** app-server v2 `account/rateLimits/read` and `account/rateLimits/updated`. */
export function decodeCodexUsage(payload: JSONObject): AgentUsage {
  const bucket = (value: unknown): { limitId?: string; limitName?: string; primary?: unknown; secondary?: unknown } => {
    if (!isObject(value)) throw malformed("rate limit");
    return { limitId: optionalString(value.limitId, "limit id"), limitName: optionalString(value.limitName, "limit name"), primary: value.primary, secondary: value.secondary };
  };
  const window = (id: string, value: unknown): AgentUsageWindow | undefined => {
    if (value === undefined || value === null) return undefined;
    if (!isObject(value)) throw malformed("rate limit window");
    const usedPercent = optionalNumber(value.usedPercent, "usedPercent");
    const durationMinutes = optionalInt(value.windowDurationMins, "windowDurationMins");
    const resetsAt = optionalNumber(value.resetsAt, "resetsAt");
    return {
      id, ...(usedPercent !== undefined ? { usedPercent } : {}), ...(durationMinutes !== undefined ? { durationMinutes } : {}),
      ...(resetsAt !== undefined ? { resetsAt: resetsAt * 1000 } : {}),
    };
  };
  let entries: Record<string, ReturnType<typeof bucket>>;
  const byID = payload.rateLimitsByLimitId;
  if (isObject(byID) && Object.keys(byID).length > 0) {
    entries = Object.fromEntries(Object.entries(byID).map(([k, v]) => [k, bucket(v)]));
  } else if (payload.rateLimits !== undefined && payload.rateLimits !== null) {
    const single = bucket(payload.rateLimits);
    entries = { [single.limitId ?? "codex"]: single };
  } else {
    throw new ProcessFailure("exited", "The CLI returned no account usage limits.");
  }
  const buckets: AgentUsageBucket[] = Object.keys(entries).sort().map((key) => {
    const b = entries[key];
    const windows = [window("primary", b.primary), window("secondary", b.secondary)].filter((w): w is AgentUsageWindow => w !== undefined);
    return { id: key, title: b.limitName ?? b.limitId ?? key, windows };
  });
  return { buckets, fetchedAt: Date.now() };
}

/**
 * app-server v2 ThreadTokenUsageUpdatedNotification, CLI 0.158.0-alpha.2.1. Last-response total
 * approximates occupied context; cumulative totals are not context size.
 */
export function decodeCodexConversationUsage(payload: JSONObject): ConversationUsage {
  const count = (value: unknown, required: boolean): number | undefined => {
    if (value === undefined || value === null) {
      if (required) throw new ProcessFailure("exited", "Missing token count.");
      return undefined;
    }
    if (typeof value !== "number" || !Number.isInteger(value)) throw new ProcessFailure("exited", "Invalid token count.");
    if (value < 0) throw new ProcessFailure("exited", "Invalid negative token count.");
    return value;
  };
  const breakdown = (value: unknown): TokenCounts => {
    if (!isObject(value)) throw new ProcessFailure("exited", "Missing token usage.");
    const counts: TokenCounts = { total: count(value.totalTokens, true)! };
    const input = count(value.inputTokens, false), cached = count(value.cachedInputTokens, false);
    const write = count(value.cacheWriteInputTokens, false), output = count(value.outputTokens, false);
    const reasoning = count(value.reasoningOutputTokens, false);
    if (input !== undefined) counts.input = input;
    if (cached !== undefined) counts.cachedInput = cached;
    if (write !== undefined) counts.cacheWriteInput = write;
    if (output !== undefined) counts.output = output;
    if (reasoning !== undefined) counts.reasoning = reasoning;
    return counts;
  };
  const usage = payload.tokenUsage;
  if (!isObject(usage)) throw new ProcessFailure("exited", "Missing token usage.");
  const latest = breakdown(usage.last), session = breakdown(usage.total);
  let contextWindow: number | undefined;
  if (usage.modelContextWindow !== undefined && usage.modelContextWindow !== null) {
    if (typeof usage.modelContextWindow !== "number" || !Number.isInteger(usage.modelContextWindow)) throw new ProcessFailure("exited", "Invalid context window.");
    if (usage.modelContextWindow > 0) contextWindow = usage.modelContextWindow;
  }
  return { latest, session, ...(contextWindow !== undefined ? { contextWindow } : {}), updatedAt: Date.now() };
}

/** app-server v2 `model/list` page entries. */
export function decodeCodexModel(value: unknown): AgentModel {
  if (!isObject(value)) throw malformed("model");
  const text = (key: string) => { if (typeof value[key] !== "string") throw malformed("model"); return value[key] as string; };
  const flag = (key: string) => { if (typeof value[key] !== "boolean") throw malformed("model"); return value[key] as boolean; };
  if (!Array.isArray(value.supportedReasoningEfforts)) throw malformed("model");
  const efforts: ReasoningOption[] = value.supportedReasoningEfforts.map((option) => {
    if (!isObject(option) || typeof option.reasoningEffort !== "string" || typeof option.description !== "string") throw malformed("model");
    return { reasoningEffort: option.reasoningEffort, description: option.description };
  });
  let inputModalities: string[] | undefined;
  if (value.inputModalities !== undefined && value.inputModalities !== null) {
    if (!Array.isArray(value.inputModalities) || !value.inputModalities.every((m) => typeof m === "string")) throw malformed("model");
    inputModalities = value.inputModalities as string[];
  }
  return {
    model: text("model"), displayName: text("displayName"), description: text("description"), hidden: flag("hidden"),
    isDefault: flag("isDefault"), defaultReasoningEffort: text("defaultReasoningEffort"),
    ...(inputModalities ? { inputModalities } : {}), supportedReasoningEfforts: efforts,
  };
}
