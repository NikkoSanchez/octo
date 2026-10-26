// The state the main process publishes to the renderer. The renderer mirrors it read-only; every
// change goes through a command. Values are plain data so they cross IPC unchanged.
import type { AgentCommand, AgentModel, AgentUsage, ClaudeAuthStatus, CommitMessageModel, HarnessDescriptor, AgentInteraction } from "@octo/agents";
import type { AppTheme, BrowserAnnotation, ChatMessage, CodeAttachment, HarnessID, ImageAttachment, WorkspaceArchive } from "@octo/core";

export interface PendingApproval {
  id: string;
  title: string;
  detail: string;
}

/** Explicitly submitted snapshots waiting for delivery, local to this app session. */
export interface QueuedMessage {
  id: string;
  message: ChatMessage;
  harness: HarnessID;
  directory: string;
}

/** Draft attachments. Draft text lives in the renderer; images and captures live here so main can add them. */
export interface DraftAttachments {
  images: ImageAttachment[];
  code: CodeAttachment[];
  annotations: BrowserAnnotation[];
}

export interface AppState {
  archive: WorkspaceArchive;
  /** False when the archive could not be loaded; nothing is written for this launch. */
  canSave: boolean;
  theme: AppTheme;
  /** True when the system appearance is dark, for the System theme. */
  systemDark: boolean;
  codexExecutablePath?: string;
  codexVersion: string;
  descriptors: HarnessDescriptor[];
  commitMessageModel?: CommitMessageModel;
  running: string[];
  stopping: string[];
  queued: Record<string, QueuedMessage[]>;
  steering: Record<string, string>;
  queueErrors: Record<string, string>;
  pausedQueues: string[];
  approvals: Record<string, PendingApproval[]>;
  interactions: Record<string, AgentInteraction[]>;
  drafts: Record<string, DraftAttachments>;
  importingImages: string[];
  modelCatalogs: Record<string, AgentModel[]>;
  modelErrors: Record<string, string>;
  loadingModels: string[];
  commandCatalogs: Record<string, AgentCommand[]>;
  commandErrors: Record<string, string>;
  loadingCommands: string[];
  claudeAuth?: ClaudeAuthStatus;
  claudeAuthError?: string;
  checkingClaudeAuth: boolean;
  usageSnapshots: Record<string, AgentUsage>;
  usageErrors: Record<string, string>;
  loadingUsage: string[];
  /** Open in target for files and checkouts, as chosen in the project actions. */
  openTarget: string;
  /** A message to show in an alert; cleared by the renderer. */
  error?: string;
}

export interface StatePatch {
  op: "replace" | "remove" | "add";
  path: (string | number)[];
  value?: unknown;
}

export interface StateSnapshot {
  version: number;
  state: AppState;
}

export interface StatePatches {
  version: number;
  patches: StatePatch[];
}
