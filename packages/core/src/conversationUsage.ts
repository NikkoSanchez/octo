/** Provider-reported counts. Cached input and reasoning are subsets, not extra tokens. */
export interface TokenCounts {
  total: number;
  input?: number;
  cachedInput?: number;
  cacheWriteInput?: number;
  output?: number;
  reasoning?: number;
}

/** A replacement snapshot, never an increment. `latest` describes one model response, not a turn. */
export interface ConversationUsage {
  latest: TokenCounts;
  /** Cumulative thread totals; absent when the provider's session log cannot be read. */
  session?: TokenCounts;
  contextWindow?: number;
  /** Occupied context when the provider measures it separately; otherwise the latest response total. */
  contextTokens?: number;
  /** The provider's reported automatic-compaction point, when it reports one. */
  autoCompactThreshold?: number;
  updatedAt: number;
}

export function usedTokens(usage: ConversationUsage): number {
  return usage.contextTokens ?? usage.latest.total;
}

export function usedFraction(usage: ConversationUsage): number | undefined {
  const used = usedTokens(usage);
  if (!usage.contextWindow || usage.contextWindow <= 0 || used < 0) return undefined;
  return Math.min(1, used / usage.contextWindow);
}

export function remainingTokens(usage: ConversationUsage): number | undefined {
  const used = usedTokens(usage);
  if (!usage.contextWindow || usage.contextWindow <= 0 || used < 0) return undefined;
  return Math.max(0, usage.contextWindow - used);
}

export function percentUsed(usage: ConversationUsage): number | undefined {
  const fraction = usedFraction(usage);
  return fraction === undefined ? undefined : Math.round(fraction * 100);
}

function countsEqual(a: TokenCounts | undefined, b: TokenCounts | undefined): boolean {
  if (!a || !b) return a === b;
  return a.total === b.total && a.input === b.input && a.cachedInput === b.cachedInput &&
    a.cacheWriteInput === b.cacheWriteInput && a.output === b.output && a.reasoning === b.reasoning;
}

/** True when another snapshot differs in anything but its timestamp. */
export function usageDiffersInCounts(usage: ConversationUsage, other: ConversationUsage | undefined): boolean {
  if (!other) return true;
  return !countsEqual(usage.latest, other.latest) || !countsEqual(usage.session, other.session) ||
    usage.contextWindow !== other.contextWindow || usage.contextTokens !== other.contextTokens ||
    usage.autoCompactThreshold !== other.autoCompactThreshold;
}

export interface ContextCompaction {
  id: string;
  state: "compacting" | "completed" | "interrupted";
  startedAt: number;
  endedAt?: number;
}
