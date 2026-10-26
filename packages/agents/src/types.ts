import type { AgentPermissionMode, AgentSettings, ContextCompaction, ConversationUsage, HarnessID, ImageAttachment, ToolActivity } from "@octo/core";
import type { AgentInteraction, AgentInteractionResponse } from "./interaction";

/** Each capability describes implemented adapter/UI support, not installed tools or account access. */
export interface HarnessCapabilities {
  toolActivity: boolean;
  steering: boolean;
  textToolResults: boolean;
  structuredToolResults: boolean;
  toolInventory: boolean;
  forms: boolean;
  toolQuestions: boolean;
  appAccess: boolean;
  urlElicitation: boolean;
}

const NO_CAPABILITIES: HarnessCapabilities = {
  toolActivity: false, steering: false, textToolResults: false, structuredToolResults: false,
  toolInventory: false, forms: false, toolQuestions: false, appAccess: false, urlElicitation: false,
};

export const CLAUDE_CAPABILITIES: HarnessCapabilities = { ...NO_CAPABILITIES, toolActivity: true, textToolResults: true, toolQuestions: true };
export const CODEX_CAPABILITIES: HarnessCapabilities = {
  ...NO_CAPABILITIES, steering: true, toolActivity: true, textToolResults: true, structuredToolResults: true,
  forms: true, toolQuestions: true, appAccess: true,
};

export interface AgentPermissionOption {
  mode: AgentPermissionMode;
  title: string;
  detail: string;
}

export interface HarnessDescriptor {
  id: HarnessID;
  executable?: string;
  supportsApprovals: boolean;
  detail: string;
  permissionOptions: AgentPermissionOption[];
  defaultPermissionMode?: AgentPermissionMode;
  supportsModels: boolean;
  supportsImages: boolean;
  supportsUsageLimits: boolean;
  /** False when limits arrive only as stream events (no read-only query exists). */
  supportsUsageRefresh: boolean;
  supportsConversationUsage: boolean;
  supportsCompactionStatus: boolean;
  capabilities: HarnessCapabilities;
}

/** An operation the agent wants approved. `respond` is only valid for the connection and turn that raised it. */
export interface AgentApproval {
  id: string;
  title: string;
  detail: string;
  respond: (allow: boolean) => void;
}

export type AgentEvent =
  | { type: "session"; id: string }
  | { type: "textDelta"; text: string }
  | { type: "message"; text: string }
  | { type: "activity"; text: string }
  | { type: "activityDelta"; text: string }
  | { type: "reasoningDelta"; text: string }
  | { type: "usage"; usage: AgentUsage }
  | { type: "conversationUsage"; usage: ConversationUsage }
  | { type: "compaction"; compaction: ContextCompaction }
  | { type: "toolActivity"; tool: ToolActivity }
  | { type: "interaction"; interaction: AgentInteraction }
  | { type: "interactionResolved"; id: string }
  | { type: "interactionUnavailable"; text: string }
  | { type: "approval"; approval: AgentApproval }
  | { type: "approvalResolved"; id: string }
  | { type: "finished" }
  | { type: "interrupted" }
  | { type: "failed"; text: string };

export interface AgentHarness {
  onEvent?: (event: AgentEvent) => void;
  send(prompt: string, sessionID: string | undefined, directory: string, settings?: AgentSettings, images?: ImageAttachment[]): Promise<void>;
  steer(prompt: string, images?: ImageAttachment[]): Promise<void>;
  respond(id: string, response: AgentInteractionResponse): void;
  interrupt(): Promise<void>;
  shutdown(): void;
}

/** Account limits, not a token count for this conversation. Never infer missing limits as zero. */
export interface AgentUsage {
  buckets: AgentUsageBucket[];
  fetchedAt: number;
}

export interface AgentUsageBucket {
  id: string;
  title: string;
  windows: AgentUsageWindow[];
}

export interface AgentUsageWindow {
  id: string;
  usedPercent?: number;
  durationMinutes?: number;
  resetsAt?: number;
  /** Provider label when the duration alone is ambiguous (for example per-model weekly limits). */
  name?: string;
  /** The provider reported this window as currently rejecting requests. */
  isLimited?: boolean;
}

export function remainingPercent(window: AgentUsageWindow): number | undefined {
  return window.usedPercent === undefined ? undefined : Math.max(0, Math.min(100, 100 - window.usedPercent));
}

export function windowTitle(window: AgentUsageWindow): string {
  if (window.name !== undefined) return window.name;
  const minutes = window.durationMinutes;
  if (!minutes || minutes <= 0) return window.id.charAt(0).toUpperCase() + window.id.slice(1) + " window";
  if (minutes === 10_080) return "Weekly";
  if (minutes % 1_440 === 0) return `${minutes / 1_440}-day window`;
  if (minutes % 60 === 0) return `${minutes / 60}-hour window`;
  return `${minutes}-minute window`;
}

/** Pushed updates may describe only the window that changed; keep other last-known windows. */
export function mergeUsage(update: AgentUsage, existing: AgentUsage | undefined): AgentUsage {
  const buckets = (existing?.buckets ?? []).map((b) => ({ ...b, windows: [...b.windows] }));
  for (const bucket of update.buckets) {
    const index = buckets.findIndex((b) => b.id === bucket.id);
    if (index === -1) { buckets.push({ ...bucket, windows: [...bucket.windows] }); continue; }
    const windows = [...buckets[index].windows];
    for (const window of bucket.windows) {
      const position = windows.findIndex((w) => w.id === window.id);
      if (position === -1) windows.push(window); else windows[position] = window;
    }
    buckets[index] = { ...bucket, windows };
  }
  return { ...update, buckets: buckets.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)) };
}

/** Provider-neutral catalog consumed by the composer. Values come from the installed CLI. */
export interface AgentModel {
  model: string;
  displayName: string;
  description: string;
  hidden: boolean;
  isDefault: boolean;
  defaultReasoningEffort: string;
  inputModalities?: string[];
  supportedReasoningEfforts: ReasoningOption[];
}

export function modelSupportsImages(model: AgentModel): boolean {
  return model.inputModalities?.includes("image") ?? true;
}

export interface ReasoningOption {
  reasoningEffort: string;
  description: string;
}

export function reasoningTitle(effort: string): string {
  return effort === "xhigh" ? "Extra high" : effort.charAt(0).toUpperCase() + effort.slice(1);
}

/** User-invocable entries advertised by the provider, never inferred from skill files. */
export interface AgentCommand {
  name: string;
  description: string;
  argumentHint: string;
  skillPath?: string;
}
