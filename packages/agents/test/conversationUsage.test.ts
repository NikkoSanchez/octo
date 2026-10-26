import { describe, expect, it } from "vitest";
import { percentUsed, remainingTokens, usedFraction, type ContextCompaction, type ConversationUsage } from "@octo/core";
import { CodexHarness, decodeCodexConversationUsage } from "../src";
import { deferred, fixture, fixtures, untilEnd, within } from "./helpers";

const usageFixture = fixture("codex-usage.py");

describe("Codex conversation usage", () => {
  it("decodes unknown capacity and rejects invalid counts", () => {
    const payload = (last: Record<string, unknown>, capacity: unknown = null) => ({ tokenUsage: { last, total: { totalTokens: 900_000 }, modelContextWindow: capacity } });
    const usage = decodeCodexConversationUsage(payload({ totalTokens: 80_000, inputTokens: 70_000, cachedInputTokens: 60_000, outputTokens: 10_000, reasoningOutputTokens: 5_000 }, 200_000));
    expect(percentUsed(usage)).toBe(40);
    expect(remainingTokens(usage)).toBe(120_000);
    expect(usage.session?.total).toBe(900_000);
    expect(usage.latest.total).toBe(80_000);
    expect(usage.latest.cacheWriteInput).toBeUndefined();
    for (const capacity of [null, 0, -1]) {
      const unknown = decodeCodexConversationUsage(payload({ totalTokens: 0 }, capacity));
      expect(usedFraction(unknown)).toBeUndefined();
      expect(remainingTokens(unknown)).toBeUndefined();
      expect(unknown.latest.input).toBeUndefined();
    }
    const full = decodeCodexConversationUsage(payload({ totalTokens: Number.MAX_SAFE_INTEGER }, 1));
    expect(percentUsed(full)).toBe(100);
    expect(remainingTokens(full)).toBe(0);
    for (const invalid of [-1, true, "123", 1.5]) expect(() => decodeCodexConversationUsage(payload({ totalTokens: invalid }))).toThrow();
    expect(() => decodeCodexConversationUsage(payload({ totalTokens: 5, inputTokens: -1 }))).toThrow();
    expect(() => decodeCodexConversationUsage({})).toThrow();
  });

  it("routes framed usage and compaction on new, resumed and subsequent turns", async () => {
    for (const session of [undefined, "resumed-fixture"]) {
      const harness = new CodexHarness(usageFixture);
      try {
        for (const prompt of ["normal", "unknown"]) {
          const snapshots: ConversationUsage[] = [], states: ContextCompaction["state"][] = [];
          const finalUsage = deferred();
          const end = untilEnd(harness, (event) => {
            if (event.type === "conversationUsage") { snapshots.push(event.usage); if (event.usage.latest.total === 32_000) finalUsage.resolve(); }
            if (event.type === "compaction") states.push(event.compaction.state);
            if (event.type === "failed") throw new Error(event.text);
          });
          await harness.send(prompt, session, fixtures);
          await within(Promise.all([end, finalUsage.promise]), 10000);
          expect(snapshots.map((s) => s.latest.total)).toEqual([184_000, 184_000, 184_000, 32_000]);
          expect(snapshots.at(-1)?.session?.total).toBe(854_000);
          expect(snapshots.at(-1)?.contextWindow).toBe(prompt === "unknown" ? undefined : 200_000);
          expect(states).toEqual(["compacting", "completed"]);
        }
      } finally { harness.shutdown(); }
    }
  });

  it("does not report compaction completion after a disconnect or interrupt", async () => {
    for (const prompt of ["hold", "disconnect"]) {
      const harness = new CodexHarness(usageFixture);
      try {
        const states: ContextCompaction["state"][] = [];
        const started = deferred();
        const end = untilEnd(harness, (event) => { if (event.type === "compaction") { states.push(event.compaction.state); started.resolve(); } });
        await harness.send(prompt, undefined, fixtures);
        await within(started.promise, 10000);
        if (prompt === "hold") await harness.interrupt();
        await within(end, 10000);
        expect(states).toEqual(["compacting"]);
      } finally { harness.shutdown(); }
    }
  });
});
