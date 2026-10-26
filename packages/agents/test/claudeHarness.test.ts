import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { makeImage, usedFraction, type AgentPermissionMode, type ContextCompaction, type ConversationUsage, type ToolActivity } from "@octo/core";
import {
  ClaudeHarness, ClaudeTranscriptUsage, decodeClaudeContextUsage, decodeClaudeRateLimit, mergeUsage, remainingPercent, textValue, windowTitle,
  type AgentApproval, type AgentUsage,
} from "../src";
import { deferred, dedent, executable, fixture, removeRoot, sleep, temporaryRoot, untilEnd, within } from "./helpers";

const stream = fixture("claude-stream.py");
const roots: string[] = [];
const root = () => { const r = temporaryRoot(); roots.push(r); return r; };
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

function frames(directory: string): Record<string, unknown>[] {
  return readFileSync(join(directory, ".claude-fixture-trace.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

function writeTranscript(projects: string): void {
  const project = join(projects, "-tmp-project");
  mkdirSync(project, { recursive: true });
  const first = '{"type":"assistant","sessionId":"fixture-session","requestId":"r1","timestamp":"2026-10-16T10:00:00Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":60000,"cache_creation_input_tokens":1000,"output_tokens":400}}}';
  const second = '{"type":"assistant","sessionId":"fixture-session","requestId":"r2","timestamp":"2026-10-16T10:01:00Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"output_tokens":50}}}';
  writeFileSync(join(project, "fixture-session.jsonl"), [first, first, '{"type":"user","message":{"content":"usage"}}', second].join("\n"));
}

describe("ClaudeHarness", () => {
  it("discovers models and enforces settings and permission boundaries", async () => {
    const models = await ClaudeHarness.models("/tmp", stream);
    expect(models.map((m) => m.model)).toEqual(["default", "sonnet", "haiku"]);
    expect(models[1].supportedReasoningEfforts.map((e) => e.reasoningEffort)).toEqual(["low", "high"]);
    expect(models[2].supportedReasoningEfforts).toEqual([]);
    expect(models[1].defaultReasoningEffort).toBe("");
    const args = ClaudeHarness.arguments({ model: "sonnet", reasoningEffort: "high", permissionMode: "ask" }, "--dangerously-skip-permissions");
    expect(args.includes("--resume=--dangerously-skip-permissions")).toBe(true);
    expect(args.includes("--dangerously-skip-permissions")).toBe(false);
    for (const mode of ["readOnly", "fullAccess"] as AgentPermissionMode[]) expect(() => ClaudeHarness.arguments({ permissionMode: mode }, undefined)).toThrow();
    expect(() => ClaudeHarness.decodeModels({})).toThrow();
    const harness = new ClaudeHarness(stream);
    try {
      await expect(harness.send("unsent", undefined, "/tmp", { model: "haiku", reasoningEffort: "high" })).rejects.toThrow(/effort/);
    } finally { harness.shutdown(); }
  });

  it("rejects unavailable and broader permission confirmations", () => {
    ClaudeHarness.validatePermissions({ current_permission_mode: "auto" }, {});
    for (const mode of ["default", "manual"]) {
      ClaudeHarness.validatePermissions({ current_permission_mode: mode }, { permissionMode: "ask" });
      expect(() => ClaudeHarness.validatePermissions({ current_permission_mode: mode }, {})).toThrow();
    }
    expect(() => ClaudeHarness.validatePermissions({}, {})).toThrow();
    expect(() => ClaudeHarness.validatePermissions({ current_permission_mode: "bypassPermissions" }, { permissionMode: "autoReview" })).toThrow();
    expect(() => ClaudeHarness.validatePermissions({ current_permission_mode: "auto" }, { permissionMode: "ask" })).toThrow();
    ClaudeHarness.validatePermissions({}, { permissionMode: "ask" });
  });

  it("defaults to Auto and applies permission transitions on resume", async () => {
    const directory = root();
    writeFileSync(join(directory, ".claude-fixture-permissions.json"), '{"trace":true}');
    const harness = new ClaudeHarness(stream);
    try {
      for (const [index, mode] of ([undefined, "ask", "autoReview"] as (AgentPermissionMode | undefined)[]).entries()) {
        const end = untilEnd(harness);
        await harness.send("permissions", index === 0 ? undefined : "fixture-session", directory, { permissionMode: mode });
        expect(await within(end, 5000)).toEqual({ type: "finished" });
      }
    } finally { harness.shutdown(); }
    const all = frames(directory);
    const argv = all.filter((f) => Array.isArray(f.argv)).map((f) => f.argv as string[]);
    expect(argv.map((a) => a[a.indexOf("--permission-mode") + 1])).toEqual(["auto", "manual", "auto"]);
    expect(argv[0].includes("--resume=fixture-session")).toBe(false);
    expect(argv.slice(1).every((a) => a.includes("--resume=fixture-session"))).toBe(true);
    expect(all.filter((f) => f.type === "user").length).toBe(3);
  });

  it("never submits a prompt when Auto is unavailable, and discovery still works", async () => {
    const directory = root();
    writeFileSync(join(directory, ".claude-fixture-permissions.json"), '{"reported_mode":"default"}');
    const harness = new ClaudeHarness(stream);
    try {
      await expect(harness.send("must stay unsent", "fixture-session", directory)).rejects.toThrow(/did not enable/);
      expect((await ClaudeHarness.models(directory, stream)).length).toBeGreaterThan(0);
      expect(readFileSync(join(directory, ".claude-fixture-trace.jsonl"), "utf8").includes("must stay unsent")).toBe(false);
    } finally { harness.shutdown(); }
  });

  it("makes a runtime permission fallback visible", async () => {
    const directory = root();
    writeFileSync(join(directory, ".claude-fixture-permissions.json"), '{"runtime_mode":"default"}');
    const harness = new ClaudeHarness(stream);
    try {
      const notices: string[] = [];
      const end = untilEnd(harness, (e) => { if (e.type === "interactionUnavailable") notices.push(e.text); });
      await harness.send("permissions", undefined, directory);
      expect(await within(end, 5000)).toEqual({ type: "finished" });
      expect(notices.length).toBe(1);
      expect(notices[0]).toContain("changed its permission mode");
    } finally { harness.shutdown(); }
  });

  it("streams fragments, resumes, sends images, approves and deduplicates tools", async () => {
    const harness = new ClaudeHarness(stream);
    try {
      for (const [index, prompt] of ["stream", "image"].entries()) {
        let output = "", session: string | undefined, approvals = 0, finishes = 0;
        const tools: ToolActivity[] = [];
        const end = untilEnd(harness, (event) => {
          if (event.type === "textDelta" || event.type === "message") output += event.text;
          if (event.type === "session") session = event.id;
          if (event.type === "toolActivity") tools.push(event.tool);
          if (event.type === "approval") { approvals++; event.approval.respond(index === 0); event.approval.respond(true); }
          if (event.type === "finished") finishes++;
          if (event.type === "failed") throw new Error(event.text);
        });
        await harness.send(prompt === "image" ? "" : prompt, index === 0 ? undefined : "fixture-session", "/tmp",
          { model: "sonnet", reasoningEffort: "high", permissionMode: "ask" }, [makeImage(Buffer.from("fixture-image").toString("base64"))]);
        await within(end, 5000);
        expect(output).toBe("Hello 🐙 again fallback");
        if (index === 0) expect(session).toBe("fixture-session");
        expect(finishes).toBe(1); expect(approvals).toBe(1);
        expect(tools.map((t) => t.state)).toEqual(["running", "completed"]);
        expect(tools.at(-1)?.detail.includes("secret-value")).toBe(false);
      }
    } finally { harness.shutdown(); }
  });

  it("validates questions, cancels and declines unsupported schemas", async () => {
    const harness = new ClaudeHarness(stream);
    try {
      let staleID: string | undefined;
      const end = untilEnd(harness, (event) => {
        if (event.type === "interaction") {
          staleID = event.interaction.id;
          expect(() => harness.respond(event.interaction.id, { type: "submit", values: {} })).toThrow();
          harness.respond(event.interaction.id, { type: "submit", values: { "Which option?": textValue("B") } });
        }
        if (event.type === "failed") throw new Error(event.text);
      });
      await harness.send("question", undefined, "/tmp");
      expect(await within(end, 5000)).toEqual({ type: "finished" });
      expect(() => harness.respond(staleID!, { type: "cancel" })).toThrow();
      let notices = 0;
      const unsupported = untilEnd(harness, (e) => { if (e.type === "interactionUnavailable") notices++; });
      await harness.send("unsupported", undefined, "/tmp");
      expect(await within(unsupported, 5000)).toEqual({ type: "finished" });
      expect(notices).toBe(1);
    } finally { harness.shutdown(); }
  });

  it("invalidates the approval on stop and does not finish successfully", async () => {
    const harness = new ClaudeHarness(stream);
    try {
      const shown = deferred();
      let pending: AgentApproval | undefined, interrupted = 0, finished = 0, resolved = 0;
      harness.onEvent = (event) => {
        if (event.type === "approval") { pending = event.approval; shown.resolve(); }
        if (event.type === "interrupted") interrupted++;
        if (event.type === "finished") finished++;
        if (event.type === "approvalResolved") resolved++;
      };
      await harness.send("hold", undefined, "/tmp");
      await within(shown.promise, 5000);
      await harness.interrupt(); pending?.respond(true);
      expect([interrupted, finished, resolved]).toEqual([1, 0, 1]);
      const next = untilEnd(harness, (event) => { if (event.type === "approval") event.approval.respond(false); });
      await harness.send("stream", "fixture-session", "/tmp");
      pending?.respond(true);
      expect(await within(next, 5000)).toEqual({ type: "finished" });
    } finally { harness.shutdown(); }
  });

  it("resolves the card on provider cancellation and ignores a late click", async () => {
    const harness = new ClaudeHarness(stream);
    try {
      const cancelled = deferred();
      let pending: AgentApproval | undefined;
      harness.onEvent = (event) => {
        if (event.type === "approval") pending = event.approval;
        if (event.type === "approvalResolved") cancelled.resolve();
        if (event.type === "finished") throw new Error("Cancelled request must not respond");
      };
      await harness.send("cancel-request", undefined, "/tmp");
      await within(cancelled.promise, 5000);
      pending?.respond(true);
      await harness.interrupt();
    } finally { harness.shutdown(); }
  });

  it("treats an error result and an unexpected clean exit as failures", async () => {
    for (const prompt of ["error", "disconnect"]) {
      const harness = new ClaudeHarness(stream);
      const end = untilEnd(harness);
      await harness.send(prompt, undefined, "/tmp");
      expect((await within(end, 5000)).type).toBe("failed");
      harness.shutdown();
    }
  });

  it("never sends the prompt when shut down during initialization", async () => {
    const directory = root();
    const script = executable(directory, "delayed", "#!/usr/bin/python3\nimport time\ntime.sleep(10)\n");
    const harness = new ClaudeHarness(script);
    const send = harness.send("must not send", undefined, directory);
    await sleep(30);
    harness.shutdown();
    await expect(send).rejects.toThrow();
  });

  it("merges rate limit events into account usage", async () => {
    const harness = new ClaudeHarness(stream);
    try {
      let snapshot: AgentUsage | undefined, updates = 0;
      const end = untilEnd(harness, (e) => { if (e.type === "usage") { updates++; snapshot = mergeUsage(e.usage, snapshot); } });
      await harness.send("ratelimit", undefined, "/tmp", {});
      expect(await within(end, 5000)).toEqual({ type: "finished" });
      expect(updates).toBe(2);
      const windows = snapshot!.buckets.find((b) => b.id === "claude")!.windows;
      expect(windows.map((w) => w.id)).toEqual(["seven_day", "five_hour"]);
      expect(windows[0].usedPercent).toBeCloseTo(82, 3);
      expect(windowTitle(windows[0])).toBe("Weekly · all models");
      expect(windows[0].resetsAt).toBe(1_800_000_000_000);
      expect(remainingPercent(windows[1])).toBeCloseTo(75, 3);
      expect(windows.some((w) => w.isLimited)).toBe(false);
    } finally { harness.shutdown(); }
  });

  it("keeps unknown rate limit values unknown", () => {
    expect(decodeClaudeRateLimit({})).toBeUndefined();
    expect(decodeClaudeRateLimit({ status: "allowed" })).toBeUndefined();
    const window = decodeClaudeRateLimit({ status: "rejected", rateLimitType: "seven_day_opus" })!.buckets[0].windows[0];
    expect(window.isLimited).toBe(true);
    expect(window.usedPercent).toBeUndefined();
    expect(window.resetsAt).toBeUndefined();
    expect(windowTitle(window)).toBe("Weekly · Opus");
    const combined = decodeClaudeRateLimit({ status: "allowed", rateLimitType: "five_hour", utilization: 1.3,
      unifiedWindows: { seven_day: { utilization: 0.4, resetsAt: 1_800_000_000 }, five_hour: { utilization: 1.3, resetsAt: 1_790_000_000 } } })!;
    expect(combined.buckets[0].windows.map((w) => w.id)).toEqual(["five_hour", "seven_day"]);
    expect(remainingPercent(combined.buckets[0].windows[0])).toBe(0);
    expect(combined.buckets[0].windows[0].resetsAt).toBe(1_790_000_000_000);
    const unknown = decodeClaudeRateLimit({ rateLimitType: "future_window", utilization: -1 })!;
    expect(unknown.buckets[0].windows[0].usedPercent).toBeUndefined();
    expect(unknown.buckets[0].windows[0].durationMinutes).toBeUndefined();
  });

  it("keeps unknown context usage unknown", () => {
    const api = { input_tokens: 2, output_tokens: 400, cache_creation_input_tokens: 1000, cache_read_input_tokens: 60000 };
    const response = { totalTokens: 61002, maxTokens: 1_000_000, autoCompactThreshold: 967_000, isAutoCompactEnabled: true, apiUsage: api };
    const usage = decodeClaudeContextUsage(response, { total: 9 })!;
    expect(usage.contextTokens).toBe(61002);
    expect(usage.latest).toEqual({ total: 61402, input: 61002, cachedInput: 60000, cacheWriteInput: 1000, output: 400 });
    expect(usage.session).toEqual({ total: 9 });
    expect(usage.contextWindow).toBe(1_000_000);
    expect(usage.autoCompactThreshold).toBe(967_000);
    expect(decodeClaudeContextUsage({ ...response, apiUsage: null }, undefined)).toBeUndefined();
    for (const invalid of [-1, true, "61002", 1.5]) expect(decodeClaudeContextUsage({ ...response, totalTokens: invalid }, undefined)).toBeUndefined();
    const unknown = decodeClaudeContextUsage({ ...response, maxTokens: 0, isAutoCompactEnabled: false }, undefined)!;
    expect(usedFraction(unknown)).toBeUndefined();
    expect(unknown.autoCompactThreshold).toBeUndefined();
    expect(unknown.session).toBeUndefined();
    const huge = decodeClaudeContextUsage({ ...response, apiUsage: { input_tokens: 2 ** 62, output_tokens: 2 ** 62 } }, undefined)!;
    expect(huge.latest.total).toBe(Number.MAX_SAFE_INTEGER);
  });

  it("reads session totals from the named main transcript only", () => {
    const projects = root();
    writeTranscript(projects);
    mkdirSync(join(projects, "-other"));
    writeFileSync(join(projects, "-other", "another-session.jsonl"), '{"type":"assistant","timestamp":"2026-10-16T10:00:00Z","message":{"id":"x","usage":{"input_tokens":999}}}');
    expect(ClaudeTranscriptUsage.sessionTotals("fixture-session", projects)).toEqual({ total: 61557, input: 61107, cachedInput: 60000, cacheWriteInput: 1100, output: 450 });
    for (const session of ["", "../-project/fixture-session", ".hidden", "missing"]) expect(ClaudeTranscriptUsage.sessionTotals(session, projects)).toBeUndefined();
  });

  it("reports context usage and compaction status", async () => {
    const projects = root();
    writeTranscript(projects);
    const harness = new ClaudeHarness(stream, projects);
    try {
      for (const [prompt, expected] of [["context", "completed"], ["compact-failed", "interrupted"], ["compact-unfinished", "interrupted"]] as const) {
        const snapshots: ConversationUsage[] = [], states: ContextCompaction["state"][] = [], ids = new Set<string>();
        const final = deferred();
        const end = untilEnd(harness, (event) => {
          if (event.type === "conversationUsage") { snapshots.push(event.usage); final.resolve(); }
          if (event.type === "compaction") { states.push(event.compaction.state); ids.add(event.compaction.id); }
          if (event.type === "failed") throw new Error(event.text);
        });
        await harness.send(prompt, undefined, "/tmp");
        await within(Promise.all([end, final.promise]), 10000);
        await sleep(200);
        expect(states, prompt).toEqual(["compacting", expected]);
        expect(ids.size).toBe(1);
        const usage = snapshots.at(-1)!;
        expect(usage.contextTokens).toBe(prompt === "context" ? 12000 : 61002);
        expect(usage.contextWindow).toBe(1_000_000);
        expect(usage.autoCompactThreshold).toBe(967_000);
        expect(usage.session?.total).toBe(61557);
        expect(usage.latest.total).toBe(prompt === "context" ? 155 : 61402);
      }
      let reported = 0;
      const quiet = untilEnd(harness, (e) => { if (e.type === "conversationUsage") reported++; });
      await harness.send("permissions", "fixture-session", "/tmp");
      await within(quiet, 5000);
      await sleep(200);
      expect(reported).toBe(0);
    } finally { harness.shutdown(); }
  });
});
