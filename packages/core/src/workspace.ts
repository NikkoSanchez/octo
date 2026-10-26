import { DISTANT_PAST } from "./dates";
import { newID } from "./ids";
import type { BrowserAnnotation } from "./browserAnnotation";
import type { ContextCompaction, ConversationUsage } from "./conversationUsage";
import { createPanelTabs, type PanelTabs } from "./panelTabs";
import type { CodeAttachment } from "./review";
import type { ToolActivity } from "./toolActivity";

export type HarnessID = "codex" | "claude";
export const HARNESS_IDS: readonly HarnessID[] = ["codex", "claude"];
export function harnessTitle(id: HarnessID): string {
  return id === "codex" ? "Codex" : "Claude Agent";
}

/** Product intent only. Each adapter owns its mapping and supported subset. */
export type AgentPermissionMode = "readOnly" | "ask" | "autoReview" | "fullAccess";
export const PERMISSION_MODES: readonly AgentPermissionMode[] = ["readOnly", "ask", "autoReview", "fullAccess"];
export function permissionTitle(mode: AgentPermissionMode): string {
  switch (mode) {
    case "readOnly": return "Read only";
    case "ask": return "Ask for approval";
    case "autoReview": return "Approve for me";
    case "fullAccess": return "Full access";
  }
}

/** Optional overrides; older threads continue using their provider's session defaults. */
export interface AgentSettings {
  model?: string;
  reasoningEffort?: string;
  permissionMode?: AgentPermissionMode;
}

export function settingsEqual(a: AgentSettings, b: AgentSettings): boolean {
  return a.model === b.model && a.reasoningEffort === b.reasoningEffort && a.permissionMode === b.permissionMode;
}

export interface ImageAttachment {
  id: string;
  name: string;
  /** PNG bytes, base64-encoded as in the archive. */
  pngBase64: string;
}

export function makeImage(pngBase64: string, name = "Screenshot"): ImageAttachment {
  return { id: newID(), name, pngBase64 };
}

export type MessageRole = "user" | "assistant" | "activity" | "reasoning" | "error";

export interface TurnWork {
  startedAt: number;
  /** Seconds. */
  elapsed?: number;
  outcome?: "completed" | "stopped" | "failed" | "interrupted";
}

export interface ChatMessage {
  id: string;
  role: MessageRole;
  text: string;
  attachments: CodeAttachment[];
  images: ImageAttachment[];
  browserAnnotations: BrowserAnnotation[];
  createdAt: number;
  completedAt?: number;
  /** Recorded on the initiating user message. Absent on legacy conversations. */
  toolActivity?: ToolActivity;
  work?: TurnWork;
  isSteering?: boolean;
}

export function makeMessage(role: MessageRole, text: string, extra: Partial<ChatMessage> = {}): ChatMessage {
  return { id: newID(), role, text, attachments: [], images: [], browserAnnotations: [], createdAt: Date.now(), ...extra };
}

export interface WorkspaceThread {
  id: string;
  title: string;
  isTitleManuallySet: boolean;
  harness: HarnessID;
  workingDirectory: string;
  remoteSessionID?: string;
  conversationUsage?: ConversationUsage;
  lastCompaction?: ContextCompaction;
  lastVisitedAt?: number;
  lastActivityAt?: number;
  /** When a draft was last started; orders Recent without changing the row's message time. */
  lastDraftedAt?: number;
  unreadCompletedAt?: number;
  isPinned: boolean;
  agentSettings: AgentSettings;
  messages: ChatMessage[];
  createdAt: number;
}

export function makeThread(fields: { workingDirectory: string; title?: string; harness?: HarnessID; id?: string }): WorkspaceThread {
  return {
    id: fields.id ?? newID(),
    title: fields.title ?? "New thread",
    isTitleManuallySet: false,
    harness: fields.harness ?? "codex",
    workingDirectory: fields.workingDirectory,
    isPinned: false,
    agentSettings: {},
    messages: [],
    createdAt: Date.now(),
  };
}

export function hasUnreadCompletion(thread: WorkspaceThread): boolean {
  return thread.unreadCompletedAt !== undefined;
}

/** The last send or reply, shown as the row's time. */
export function threadActivityAt(thread: WorkspaceThread): number {
  const last = thread.messages[thread.messages.length - 1];
  return Math.max(thread.createdAt, thread.lastActivityAt ?? DISTANT_PAST, last ? (last.completedAt ?? last.createdAt) : DISTANT_PAST);
}

/**
 * Recent's order: the last send, reply or draft started here. Visiting a thread does not move it,
 * so clicking through Recent leaves its order alone.
 */
export function threadRecentAt(thread: WorkspaceThread): number {
  return Math.max(threadActivityAt(thread), thread.lastDraftedAt ?? DISTANT_PAST);
}

export interface WorkspaceProject {
  id: string;
  name: string;
  rootPath: string;
  threads: WorkspaceThread[];
  isPinned: boolean;
  isCollapsed: boolean;
  /** The built-in home for conversations without a user-selected repository. */
  isChatCollection: boolean;
  /** Review-panel tabs: open files and browser pages. */
  panelTabs: PanelTabs;
}

export function makeProject(fields: { name: string; rootPath: string; threads?: WorkspaceThread[]; id?: string }): WorkspaceProject {
  return {
    id: fields.id ?? newID(),
    name: fields.name,
    rootPath: fields.rootPath,
    threads: fields.threads ?? [],
    isPinned: false,
    isCollapsed: false,
    isChatCollection: false,
    panelTabs: createPanelTabs(),
  };
}

/**
 * Threads are appended on creation. Reverse presentation only, retaining archive order and keeping
 * pins ahead of the remaining conversations.
 */
export function orderedThreads(project: WorkspaceProject): WorkspaceThread[] {
  const newestFirst = [...project.threads].reverse();
  return [...newestFirst.filter((t) => t.isPinned), ...newestFirst.filter((t) => !t.isPinned)];
}

export function durationLabel(interval: number): string {
  const seconds = Math.trunc(Math.min(31_536_000, Math.max(0, Number.isFinite(interval) ? interval : 0)));
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${seconds}s`;
}

export function turnWorkLabel(work: TurnWork): string {
  let prefix: string;
  switch (work.outcome) {
    case "completed": prefix = "Worked for"; break;
    case "stopped": prefix = "Stopped after"; break;
    case "failed": prefix = "Failed after"; break;
    case "interrupted": prefix = "Interrupted after"; break;
    default: return "Interrupted";
  }
  if (work.elapsed === undefined) return work.outcome === "interrupted" ? "Interrupted" : prefix;
  return `${prefix} ${durationLabel(work.elapsed)}`;
}

/** Provider tool names grouped the way people describe the work. */
export type ToolKind = "command" | "read" | "edit" | "search" | "fetch" | "other";

export function toolKind(tool: string): ToolKind {
  switch (tool.toLowerCase()) {
    case "bash": case "shell": case "exec_command": case "commandexecution": case "local_shell": case "bashoutput": return "command";
    case "read": case "view": case "notebookread": case "read_file": return "read";
    case "edit": case "multiedit": case "write": case "notebookedit": case "apply_patch": case "str_replace_based_edit_tool": return "edit";
    case "grep": case "glob": case "ls": case "search": case "toolsearch": case "find": return "search";
    case "webfetch": case "websearch": case "web_search": case "fetch": return "fetch";
    default: return "other";
  }
}

function toolSummary(kind: ToolKind, count: number): string {
  const plural = count === 1 ? "" : "s";
  switch (kind) {
    case "command": return `ran ${count} command${plural}`;
    case "read": return `read ${count} file${plural}`;
    case "edit": return `edited ${count} file${plural}`;
    case "search": return count === 1 ? "searched once" : `searched ${count} times`;
    case "fetch": return `browsed ${count} page${plural}`;
    case "other": return `used ${count} tool${plural}`;
  }
}

function toolProgress(kind: ToolKind, tool: string): string {
  switch (kind) {
    case "command": return "Running a command";
    case "read": return "Reading a file";
    case "edit": return "Editing a file";
    case "search": return "Searching";
    case "fetch": return "Browsing";
    case "other": return `Using ${tool}`;
  }
}

const isDetail = (message: ChatMessage) => message.role === "activity" || message.role === "reasoning";

/** Contiguous details share one disclosure; user messages, answers and errors stay visible. */
export interface ChatMessageGroup {
  id: string;
  messages: ChatMessage[];
  isDetails: boolean;
}

export function messageGroups(messages: ChatMessage[]): ChatMessageGroup[] {
  const groups: ChatMessageGroup[] = [];
  for (const message of messages) {
    const last = groups[groups.length - 1];
    if (isDetail(message) && last?.isDetails) last.messages.push(message);
    else groups.push({ id: message.id, messages: [message], isDetails: isDetail(message) });
  }
  return groups;
}

/** What a collapsed run of work did, e.g. "Thought, ran 3 commands and read 2 files". */
export function groupSummary(messages: ChatMessage[]): string {
  const counts = new Map<ToolKind, number>();
  let thought = false;
  let steps = 0;
  for (const message of messages) {
    if (message.role === "reasoning") { thought = true; continue; }
    if (!message.toolActivity) {
      if (message.text.trim().length > 0) steps++;
      continue;
    }
    const kind = toolKind(message.toolActivity.tool);
    counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }
  const parts = [...counts].map(([kind, count]) => toolSummary(kind, count));
  if (steps > 0) parts.push(steps === 1 ? "1 step" : `${steps} steps`);
  if (thought) parts.unshift("thought");
  if (parts.length === 0) return "Activity";
  const text = parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}`;
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** A user message starts a turn; imported leading responses form their own group. */
export interface ChatTurn {
  id: string;
  messages: ChatMessage[];
}

export function chatTurns(messages: ChatMessage[]): ChatTurn[] {
  const turns: ChatTurn[] = [];
  for (const message of messages) {
    if ((message.role === "user" && message.isSteering !== true) || turns.length === 0) turns.push({ id: message.id, messages: [message] });
    else turns[turns.length - 1].messages.push(message);
  }
  return turns;
}

export function turnUser(turn: ChatTurn): ChatMessage | undefined {
  return turn.messages[0]?.role === "user" ? turn.messages[0] : undefined;
}

export function turnDetails(turn: ChatTurn): ChatMessage[] {
  return turn.messages.filter(isDetail);
}

export function turnResponses(turn: ChatTurn): ChatMessage[] {
  return turn.messages.filter((m) => m.role === "assistant" || m.role === "error" || m.isSteering === true);
}

/**
 * Everything after the user message in arrival order, so work stays between the replies it
 * happened between instead of gathering above them.
 */
export function turnBody(turn: ChatTurn): ChatMessageGroup[] {
  return messageGroups(turn.messages.slice(turnUser(turn) ? 1 : 0));
}

/**
 * What the agent is doing right now, for the live row under a running turn. Undefined while it
 * writes a reply, which already shows itself.
 */
export function turnLiveStatus(turn: ChatTurn): string | undefined {
  const last = turn.messages[turn.messages.length - 1];
  if (!last) return "Thinking";
  switch (last.role) {
    case "reasoning": return "Thinking";
    case "activity": {
      const tool = last.toolActivity;
      if (tool) return tool.state === "running" ? toolProgress(toolKind(tool.tool), tool.tool) : "Thinking";
      const line = (last.text.split(/\r\n|\r|\n/)[0] ?? "").trim();
      return line ? Array.from(line).slice(0, 120).join("") : "Thinking";
    }
    case "user": return "Thinking";
    case "assistant": case "error": return undefined;
  }
}

export interface WorkspaceArchive {
  // Optional fields preserve decoding of archives created before draft defaults.
  lastHarness?: HarnessID;
  rememberedAgentSettings?: Record<string, AgentSettings>;
  // Missing values preserve expanded sections in older archives.
  projectsSectionCollapsed?: boolean;
  recentSectionCollapsed?: boolean;
  schemaVersion: number;
  projects: WorkspaceProject[];
  selectedProjectID?: string;
  selectedThreadID?: string;
}

export function makeArchive(fields: Partial<WorkspaceArchive> = {}): WorkspaceArchive {
  return { schemaVersion: 1, projects: [], ...fields };
}

export interface RecentThread {
  project: WorkspaceProject;
  thread: WorkspaceThread;
}

export function chatsProject(archive: WorkspaceArchive): WorkspaceProject | undefined {
  return archive.projects.find((p) => p.isChatCollection);
}

export function orderedProjects(archive: WorkspaceArchive): WorkspaceProject[] {
  const repositories = archive.projects.filter((p) => !p.isChatCollection);
  return [...repositories.filter((p) => p.isPinned), ...repositories.filter((p) => !p.isPinned)];
}

export function searchableThreads(archive: WorkspaceArchive): RecentThread[] {
  const chats = chatsProject(archive);
  return [...(chats ? [chats] : []), ...orderedProjects(archive)].flatMap((project) =>
    orderedThreads(project).map((thread) => ({ project, thread })));
}

/** Recent conversations span projects; empty composers remain in their project. */
export function recentThreads(archive: WorkspaceArchive): RecentThread[] {
  return archive.projects
    .flatMap((project) => project.threads.filter((t) => t.messages.length > 0).map((thread) => ({ project, thread })))
    .sort((a, b) => {
      const ra = threadRecentAt(a.thread), rb = threadRecentAt(b.thread);
      if (ra !== rb) return rb - ra;
      return a.thread.id < b.thread.id ? -1 : a.thread.id > b.thread.id ? 1 : 0;
    })
    .slice(0, 8);
}

export function findProject(archive: WorkspaceArchive, id: string | undefined): WorkspaceProject | undefined {
  return id === undefined ? undefined : archive.projects.find((p) => p.id === id);
}

export function findThread(archive: WorkspaceArchive, id: string | undefined): RecentThread | undefined {
  if (id === undefined) return undefined;
  for (const project of archive.projects) {
    const thread = project.threads.find((t) => t.id === id);
    if (thread) return { project, thread };
  }
  return undefined;
}

/** Removes a thread in place; a removed selection moves to the project's first listed thread. */
export function removeThread(archive: WorkspaceArchive, id: string, projectID: string): void {
  const project = archive.projects.find((p) => p.id === projectID);
  if (!project) return;
  project.threads = project.threads.filter((t) => t.id !== id);
  if (archive.selectedThreadID === id) archive.selectedThreadID = orderedThreads(project)[0]?.id;
}

/** Removes a repository project in place. The Chats collection cannot be removed. */
export function removeProject(archive: WorkspaceArchive, id: string): void {
  if (archive.projects.find((p) => p.id === id)?.isChatCollection) return;
  archive.projects = archive.projects.filter((p) => p.id !== id);
  if (archive.selectedProjectID === id) {
    const next = orderedProjects(archive)[0] ?? chatsProject(archive);
    archive.selectedProjectID = next?.id;
    archive.selectedThreadID = next ? orderedThreads(next)[0]?.id : undefined;
  }
}
