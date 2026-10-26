import { existsSync, promises as fs, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";
import type { HarnessID, TokenCounts } from "@octo/core";
import { hourOf, makeUsageRecord, recordTotal, type UsageRecord } from "./usageSummary";
export * from "./usageSummary";

type JSONObject = Record<string, unknown>;
const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);

/** Invokes `body` for each JSON line containing one of `markers`, skipping decoding for the rest. */
function eachLine(text: string, markers: string[], body: (object: JSONObject) => void): void {
  for (const line of text.split("\n")) {
    if (!line || !markers.some((m) => line.includes(m))) continue;
    let object: unknown;
    try { object = JSON.parse(line); } catch { continue; }
    if (isObject(object)) body(object);
  }
}

function date(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? undefined : ms;
}

const int = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0);

function aggregate(records: UsageRecord[]): UsageRecord[] {
  const merged = new Map<string, UsageRecord>();
  for (const record of records) {
    const key = `${record.model}\0${record.session}\0${record.hour}`;
    const existing = merged.get(key);
    if (!existing) merged.set(key, { ...record });
    else {
      existing.cachedInput += record.cachedInput; existing.cacheWrite += record.cacheWrite;
      existing.uncachedInput += record.uncachedInput; existing.output += record.output;
    }
  }
  return [...merged.values()].filter((r) => recordTotal(r) > 0);
}

/**
 * Claude Code transcripts (`~/.claude/projects/<project>/<session>.jsonl`, checked with 2.1.302): each
 * content block of a response is written as its own `assistant` line repeating the same `message.id`
 * and `usage`, so usage is counted once per message id.
 */
export const ClaudeTranscriptUsage = {
  records(text: string, fallback: string): UsageRecord[] {
    const seen = new Set<string>();
    const records: UsageRecord[] = [];
    eachLine(text, ['"usage"'], (object) => {
      const message = isObject(object.message) ? object.message : undefined;
      const usage = message && isObject(message.usage) ? message.usage : undefined;
      const at = date(object.timestamp);
      if (object.type !== "assistant" || !message || !usage || at === undefined) return;
      if (typeof message.id === "string") {
        const id = message.id + ":" + (typeof object.requestId === "string" ? object.requestId : "");
        if (seen.has(id)) return;
        seen.add(id);
      }
      records.push({
        provider: "claude", model: typeof message.model === "string" ? message.model : "unknown",
        session: typeof object.sessionId === "string" ? object.sessionId : fallback, hour: hourOf(at),
        cachedInput: int(usage.cache_read_input_tokens), cacheWrite: int(usage.cache_creation_input_tokens),
        uncachedInput: int(usage.input_tokens), output: int(usage.output_tokens),
      });
    });
    return aggregate(records);
  },

  projectsDirectory(env: NodeJS.ProcessEnv = process.env): string {
    const root = env.CLAUDE_CONFIG_DIR ? env.CLAUDE_CONFIG_DIR : join(homedir(), ".claude");
    return join(root, "projects");
  },

  /**
   * Totals for one session's main transcript (`projects/<project>/<session>.jsonl`). Subagent
   * transcripts are separate contexts and are not included.
   */
  sessionTotals(session: string, projectsDirectory: string): TokenCounts | undefined {
    if (!session || session.length > 128 || session.includes("/") || session.startsWith(".")) return undefined;
    let projects: string[];
    try { projects = readdirSync(projectsDirectory).filter((n) => !n.startsWith(".")); } catch { return undefined; }
    let newest: { file: string; modified: number } | undefined;
    for (const project of projects) {
      const file = join(projectsDirectory, project, session + ".jsonl");
      try {
        const info = statSync(file);
        if (info.isFile() && (!newest || info.mtimeMs > newest.modified)) newest = { file, modified: info.mtimeMs };
      } catch { /* absent */ }
    }
    if (!newest) return undefined;
    let text: string;
    try { text = readFileSync(newest.file, "utf8"); } catch { return undefined; }
    const sum = makeUsageRecord({ provider: "claude", model: "", session, hour: 0 });
    for (const r of ClaudeTranscriptUsage.records(text, session)) {
      sum.cachedInput += r.cachedInput; sum.cacheWrite += r.cacheWrite; sum.uncachedInput += r.uncachedInput; sum.output += r.output;
    }
    const input = sum.uncachedInput + sum.cachedInput + sum.cacheWrite;
    return { total: input + sum.output, input, cachedInput: sum.cachedInput, cacheWriteInput: sum.cacheWrite, output: sum.output };
  },
};

/**
 * Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, checked with CLI 0.133–0.158):
 * `token_count` events carry cumulative `total_token_usage` and may repeat, so usage is the increase in
 * the cumulative total. `input_tokens` includes cached input; `output_tokens` includes reasoning. The
 * model comes from the most recent `turn_context`.
 */
export const CodexRolloutUsage = {
  records(text: string, fallback: string): UsageRecord[] {
    let model = "unknown", session = fallback;
    let previous: Record<string, number> | undefined;
    const records: UsageRecord[] = [];
    const keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"];
    eachLine(text, ['"token_count"', '"turn_context"', '"session_meta"'], (object) => {
      const payload = isObject(object.payload) ? object.payload : {};
      if (object.type === "session_meta") { if (typeof payload.id === "string" && payload.id) session = payload.id; return; }
      if (object.type === "turn_context") { if (typeof payload.model === "string" && payload.model) model = payload.model; return; }
      if (object.type !== "event_msg" || payload.type !== "token_count" || !isObject(payload.info)) return;
      const at = date(object.timestamp);
      if (at === undefined) return;
      const total = payload.info.total_token_usage;
      if (!isObject(total)) return;
      const current = Object.fromEntries(keys.map((k) => [k, int(total[k])]));
      let delta: Record<string, number>;
      if (previous && keys.every((k) => current[k] >= previous![k])) delta = Object.fromEntries(keys.map((k) => [k, current[k] - previous![k]]));
      else if (!previous) delta = current;
      else {
        // A smaller cumulative total means the counter restarted; trust the last turn only.
        const last = isObject(payload.info.last_token_usage) ? payload.info.last_token_usage : {};
        delta = Object.fromEntries(keys.map((k) => [k, int(last[k])]));
      }
      previous = current;
      const cached = delta.cached_input_tokens, write = delta.cache_write_input_tokens;
      records.push({
        provider: "codex", model, session, hour: hourOf(at), cachedInput: cached, cacheWrite: write,
        uncachedInput: Math.max(0, delta.input_tokens - cached - write), output: delta.output_tokens,
      });
    });
    return aggregate(records);
  },
};

export interface UsageSource {
  provider: HarnessID;
  directories: string[];
}

/** Scans local CLI session logs, re-reading only files whose size or modification time changed. */
export class UsageLedger {
  private readonly sources: UsageSource[];
  private cache = new Map<string, { modified: number; size: number; records: UsageRecord[] }>();

  constructor(sources: UsageSource[] = UsageLedger.defaultSources()) {
    this.sources = sources;
  }

  static defaultSources(env: NodeJS.ProcessEnv = process.env): UsageSource[] {
    const codex = env.CODEX_HOME ? env.CODEX_HOME : join(homedir(), ".codex");
    return [
      { provider: "codex", directories: [join(codex, "sessions"), join(codex, "archived_sessions")] },
      { provider: "claude", directories: [ClaudeTranscriptUsage.projectsDirectory(env)] },
    ];
  }

  /** Records from files modified at or after `since`; a file last written earlier cannot contain newer usage. */
  async records(since: number, signal?: AbortSignal): Promise<UsageRecord[]> {
    const result: UsageRecord[] = [];
    const live = new Set<string>();
    for (const source of this.sources) {
      for (const file of await transcripts(source.directories)) {
        if (signal?.aborted) return [];
        let info;
        try { info = await fs.stat(file); } catch { continue; }
        live.add(file);
        if (info.mtimeMs < since) continue;
        const cached = this.cache.get(file);
        if (cached && cached.modified === info.mtimeMs && cached.size === info.size) { result.push(...cached.records); continue; }
        let text: string;
        try { text = await fs.readFile(file, "utf8"); } catch { continue; }
        const name = basename(file, extname(file));
        const records = source.provider === "claude" ? ClaudeTranscriptUsage.records(text, name) : CodexRolloutUsage.records(text, name);
        this.cache.set(file, { modified: info.mtimeMs, size: info.size, records });
        result.push(...records);
      }
    }
    for (const key of [...this.cache.keys()]) if (!live.has(key)) this.cache.delete(key);
    return result.filter((r) => r.hour >= hourOf(since));
  }
}

async function transcripts(directories: string[]): Promise<string[]> {
  const files: string[] = [];
  const walk = async (directory: string): Promise<void> => {
    let entries;
    try { entries = await fs.readdir(directory, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) files.push(path);
    }
  };
  for (const directory of directories) if (existsSync(directory)) await walk(directory);
  return files;
}

