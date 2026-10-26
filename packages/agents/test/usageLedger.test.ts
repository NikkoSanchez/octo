import { mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ClaudeTranscriptUsage, CodexRolloutUsage, makeUsageRecord, mergeUsage, recordTotal, summarizeUsage, UsageLedger, type CalendarFunctions } from "../src";
import { removeRoot, temporaryRoot } from "./helpers";

const lines = (objects: unknown[]) => objects.map((o) => JSON.stringify(o)).join("\n") + "\n";
const claude = (id: string, time: string, input: number, cacheRead: number, cacheWrite: number, output: number, model = "claude-opus-5-5", request = "r") => ({
  type: "assistant", timestamp: time, sessionId: "s1", requestId: request,
  message: { id, model, usage: { input_tokens: input, cache_read_input_tokens: cacheRead, cache_creation_input_tokens: cacheWrite, output_tokens: output } },
});
const codex = (time: string, input: number, cached: number, output: number) => {
  const usage = { input_tokens: input, cached_input_tokens: cached, cache_write_input_tokens: 0, output_tokens: output };
  return { timestamp: time, type: "event_msg", payload: { type: "token_count", info: { total_token_usage: usage, last_token_usage: usage } } };
};
const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("Usage ledger", () => {
  it("counts each Claude message once and splits cache usage", () => {
    const text = lines([
      { type: "user", timestamp: "2026-10-01T10:00:00Z", message: { content: "usage" } },
      claude("m1", "2026-10-01T10:01:00.250Z", 2, 100, 50, 7), claude("m1", "2026-10-01T10:01:00.500Z", 2, 100, 50, 7),
      claude("m2", "2026-10-01T10:30:00Z", 1, 10, 0, 3), claude("m3", "2026-10-01T11:00:00Z", 0, 0, 0, 0, "<synthetic>"),
    ]) + 'not json "usage"\n';
    const records = ClaudeTranscriptUsage.records(text, "file");
    expect(records.length).toBe(1);
    const record = records[0];
    expect(record.session).toBe("s1");
    expect(record.hour).toBe(Date.parse("2026-10-01T10:00:00Z"));
    expect([record.uncachedInput, record.cachedInput, record.cacheWrite, record.output]).toEqual([3, 110, 50, 10]);
    expect(recordTotal(record)).toBe(173);
  });

  it("uses cumulative Codex deltas and the current model", () => {
    const records = CodexRolloutUsage.records(lines([
      { timestamp: "2026-10-01T09:00:00Z", type: "session_meta", payload: { id: "rollout-1" } },
      { timestamp: "2026-10-01T09:00:01Z", type: "turn_context", payload: { model: "gpt-6.1-sol" } },
      codex("2026-10-01T09:00:02Z", 1_000, 400, 50), codex("2026-10-01T09:00:03Z", 1_000, 400, 50),
      { timestamp: "2026-10-01T10:00:00Z", type: "turn_context", payload: { model: "gpt-6-astra" } },
      codex("2026-10-01T10:00:05Z", 3_000, 2_000, 80), codex("2026-10-01T10:10:00Z", 200, 100, 5),
    ]), "file");
    expect(records.map((r) => r.model)).toEqual(["gpt-6.1-sol", "gpt-6-astra"]);
    expect(records.map((r) => r.session)).toEqual(["rollout-1", "rollout-1"]);
    expect([records[0].uncachedInput, records[0].cachedInput, records[0].output]).toEqual([600, 400, 50]);
    expect([records[1].uncachedInput, records[1].cachedInput, records[1].output]).toEqual([500, 1_700, 35]);
  });

  it("reads sources, skips old files and refreshes changed ones", async () => {
    const root = temporaryRoot(); roots.push(root);
    const claudeDirectory = join(root, "claude/projects/p"), codexDirectory = join(root, "codex/sessions/2026/10/01");
    mkdirSync(claudeDirectory, { recursive: true }); mkdirSync(codexDirectory, { recursive: true });
    const now = Date.now(), stamp = new Date(now).toISOString();
    const claudeFile = join(claudeDirectory, "s1.jsonl"), old = join(claudeDirectory, "old.jsonl");
    writeFileSync(claudeFile, lines([claude("m1", stamp, 1, 0, 0, 1)]));
    writeFileSync(old, lines([claude("m0", stamp, 50, 0, 0, 50)]));
    const tenDaysAgo = (now - 10 * 86_400_000) / 1000;
    utimesSync(old, tenDaysAgo, tenDaysAgo);
    writeFileSync(join(codexDirectory, "rollout-a.jsonl"), lines([codex(stamp, 10, 0, 2)]));
    writeFileSync(join(codexDirectory, "notes.txt"), "ignored");
    const ledger = new UsageLedger(UsageLedger.defaultSources({ CLAUDE_CONFIG_DIR: join(root, "claude"), CODEX_HOME: join(root, "codex") }));
    let records = await ledger.records(now - 86_400_000);
    expect(records.map(recordTotal).sort((a, b) => a - b)).toEqual([2, 12]);
    writeFileSync(claudeFile, lines([claude("m1", stamp, 1, 0, 0, 1), claude("m2", stamp, 3, 0, 0, 4)]));
    records = await ledger.records(now - 86_400_000);
    expect(records.filter((r) => r.provider === "claude").map(recordTotal)).toEqual([9]);
  });

  it("fills empty buckets and ranks providers and models", () => {
    const utc: CalendarFunctions = { startOfDay: (ms) => Math.floor(ms / 86_400_000) * 86_400_000, addDay: (ms) => ms + 86_400_000 };
    const start = Date.parse("2026-10-01T00:00:00Z");
    const records = [
      makeUsageRecord({ provider: "codex", model: "gpt", session: "a", hour: start + 3_600_000, cachedInput: 60, uncachedInput: 20, output: 20 }),
      makeUsageRecord({ provider: "codex", model: "gpt", session: "b", hour: start + 2 * 86_400_000, uncachedInput: 100 }),
      makeUsageRecord({ provider: "claude", model: "opus", session: "c", hour: start + 86_400_000, cacheWrite: 25, output: 25 }),
      makeUsageRecord({ provider: "claude", model: "opus", session: "d", hour: start - 3_600_000, output: 1_000 }),
    ];
    const summary = summarizeUsage(records, { start, end: start + 3 * 86_400_000 - 1000 }, utc);
    expect(summary.hourly).toBe(false);
    expect(summary.total).toBe(250);
    expect(summary.sessions).toBe(3);
    expect(summary.providers.map((p) => p.id)).toEqual(["codex", "claude"]);
    expect([summary.cachedInput, summary.cacheWrite, summary.uncachedInput, summary.output]).toEqual([60, 25, 120, 45]);
    expect(summary.series.filter((p) => p.provider === "claude").map((p) => p.tokens)).toEqual([0, 50, 0]);
    expect(summary.models.map((m) => m.title)).toEqual(["gpt", "opus"]);
    expect(summary.models[0].share).toBeCloseTo(0.8, 4);
    expect(summary.days.map((d) => d.tokens)).toEqual([100, 50, 100]);
    const day = summarizeUsage(records, { start, end: start + 86_400_000 }, utc);
    expect(day.hourly).toBe(true);
    expect(day.series.filter((p) => p.provider === "codex").length).toBe(25);
  });

  it("keeps other windows when merging pushed limits", () => {
    const first = { buckets: [{ id: "claude", title: "Claude", windows: [{ id: "five_hour", usedPercent: 10 }, { id: "seven_day", usedPercent: 20 }] }], fetchedAt: 1 };
    const update = { buckets: [{ id: "claude", title: "Claude", windows: [{ id: "seven_day", usedPercent: 30 }] }], fetchedAt: 2 };
    const merged = mergeUsage(update, first);
    expect(merged.buckets[0].windows.map((w) => w.id)).toEqual(["five_hour", "seven_day"]);
    expect(merged.buckets[0].windows.map((w) => w.usedPercent)).toEqual([10, 30]);
    expect(merged.fetchedAt).toBe(2);
  });
});
