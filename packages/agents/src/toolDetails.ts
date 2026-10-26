// Never renders arguments, auth metadata, binary payloads, or embedded app resources. Redaction is
// defensive, not a guarantee against secrets in arbitrary tool prose.

const PATTERNS: [RegExp, string][] = [
  [/(bearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1[redacted]"],
  [/((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|authorization)\s*["']?\s*[:=]\s*["']?)[^\s,"'}]+/gi, "$1[redacted]"],
  [/\b(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,})\b/g, "[redacted]"],
];

function prefix(text: string, count: number): string {
  const points = Array.from(text);
  return points.length <= count ? text : points.slice(0, count).join("");
}
const length = (text: string) => Array.from(text).length;

export const AgentToolDetails = {
  text(text: string, limit = 8192): string {
    let value = prefix(text, 32768);
    for (const [pattern, replacement] of PATTERNS) value = value.replace(pattern, replacement);
    return prefix(value, limit) + (length(value) > limit || length(text) > 32768 ? "\n[truncated]" : "");
  },

  result(item: Record<string, unknown>): string {
    const error = item.error as Record<string, unknown> | undefined;
    if (error && typeof error === "object" && typeof error.message === "string") return AgentToolDetails.text(error.message);
    const result = item.result;
    if (!result || typeof result !== "object" || Array.isArray(result)) return "";
    const r = result as Record<string, unknown>;
    const parts: string[] = [];
    const content = Array.isArray(r.content) ? r.content : [];
    for (const block of content.slice(0, 16)) {
      const b = block as Record<string, unknown>;
      if (b && b.type === "text" && typeof b.text === "string") parts.push(AgentToolDetails.text(b.text));
      else parts.push("[Non-text result omitted]");
    }
    if (r.structuredContent !== undefined && r.structuredContent !== null) {
      try { parts.push(AgentToolDetails.text(JSON.stringify(sanitize(r.structuredContent, 0)))); } catch { /* omitted */ }
    }
    return AgentToolDetails.text(parts.join("\n"));
  },
};

const SENSITIVE_KEY = /token|secret|password|credential|authorization|cookie|api.?key|_meta/i;

function sanitize(value: unknown, depth: number): unknown {
  if (depth >= 5) return "[nested result omitted]";
  if (Array.isArray(value)) return value.slice(0, 16).map((v) => sanitize(v, depth + 1));
  if (value && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort().slice(0, 32)) {
      if (SENSITIVE_KEY.test(key)) result[key] = "[redacted]";
      else result[AgentToolDetails.text(key, 128)] = sanitize((value as Record<string, unknown>)[key], depth + 1);
    }
    return result;
  }
  if (typeof value === "string") return AgentToolDetails.text(value, 2048);
  return value;
}
