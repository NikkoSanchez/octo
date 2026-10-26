import {
  CodexExecutable, CodexHarness, HarnessRegistry, automaticCommitModels, generateCommitMessage as defaultCommitGenerator,
  generateTitle as defaultTitleGenerator, mergeUsage, modelSupportsImages, ThreadTitles, TITLE_CONFIGURATIONS, ClaudeCLI,
  commitModelStorageValue, parseCommitModel,
  type AgentEvent, type AgentHarness, type AgentInteractionResponse, type AgentModel, type CommitMessageModel, type HarnessDescriptor,
} from "@octo/agents";
import {
  annotationPromptContext, attachmentPromptContext, chatsProject, createPanelTabs, harnessTitle, isAppTheme, makeMessage, makeProject,
  makeThread, newID, orderedThreads, removeProject as removeArchiveProject, removeThread as removeArchiveThread, toolActivityText,
  usageDiffersInCounts, type AgentPermissionMode, type AgentSettings, type AppTheme, type BrowserAnnotation, type ChatMessage,
  type CodeAttachment, type HarnessID, type ImageAttachment, type PanelTabs, type StagedChanges, type TurnWork, type WorkspaceArchive,
  type WorkspaceProject, type WorkspaceThread,
} from "@octo/core";
import { findExecutable, ProcessFailure, WorkspaceArchiveWriter, type WorkspaceStore } from "@octo/core/node";
import { GitService } from "@octo/git";
import { basename } from "node:path";
import type { Draft } from "immer";
import type { AppState, DraftAttachments, QueuedMessage } from "../../shared/state";
import { applyPanelTabOperation, type PanelTabOperation } from "../../shared/panelTabs";
import { savedTarget } from "../../shared/openTargets";
import type { PreferencesFile } from "./preferences";
import { StateStore } from "./stateStore";

export type UIEvent = { type: "focusComposer" } | { type: "showTerminal" } | { type: "showThread" };

export interface PlatformServices {
  chooseDirectory(options: { title: string; prompt: string }): Promise<string | undefined>;
  chooseFile(options: { title: string; prompt: string; defaultPath?: string }): Promise<string | undefined>;
  chooseImages(): Promise<string[]>;
  /** Decodes any supported image to PNG within the draft limits, or throws. */
  decodeImage(data: Buffer, name: string): ImageAttachment;
  readImageFile(path: string): Promise<ImageAttachment>;
  clipboardImage(): Promise<Buffer | undefined>;
  systemDark(): boolean;
}

export interface StoreHooks {
  terminalTabCount(projectID: string): number;
  closeBrowser(id: string): void;
  applyTerminalTheme(theme: AppTheme): void;
}

export interface AppStoreOptions {
  storage: WorkspaceStore;
  preferences: PreferencesFile;
  platform: PlatformServices;
  hooks?: Partial<StoreHooks>;
  ui?: (event: UIEvent) => void;
  harnessFactory?: (id: HarnessID, codexExecutable: string | undefined) => AgentHarness;
  titleGenerator?: (id: HarnessID, text: string, codexExecutable: string | undefined) => Promise<string | undefined>;
  commitMessageGenerator?: (model: CommitMessageModel, changes: StagedChanges, codexExecutable: string | undefined) => Promise<string>;
  resolveExecutables?: () => { descriptors: HarnessDescriptor[]; codex: string | undefined };
  /** Milliseconds; tests shorten them. */
  timing?: { save?: number; stream?: number };
}

const EMPTY_DRAFT: DraftAttachments = { images: [], code: [], annotations: [] };
const STREAM_BYTES = 65_536;
const toggleIn = (list: string[], id: string, present: boolean) => {
  const index = list.indexOf(id);
  if (present && index === -1) list.push(id);
  if (!present && index !== -1) list.splice(index, 1);
};

/** The model prompt for a queued message: its text plus captured code and browser context. */
export function queuedPrompt(message: ChatMessage): string {
  return message.text
    + (message.attachments.length === 0 ? "" : "\n\nSelected code context (captured snapshots):\n" + message.attachments.map(attachmentPromptContext).join("\n\n"))
    + (message.browserAnnotations.length === 0 ? "" : "\n\nBrowser annotations (captured from the browser panel):\n" + message.browserAnnotations.map(annotationPromptContext).join("\n\n"));
}

/**
 * The single owner of application state in the main process: the persisted archive, one harness per
 * thread, queues, approvals and interactions, catalogs and usage. The renderer reads published state
 * and calls these intent methods; it never edits the archive directly.
 */
export class AppStore {
  readonly state: StateStore<AppState>;
  private readonly storage: WorkspaceStore;
  private readonly writer: WorkspaceArchiveWriter;
  private readonly preferences: PreferencesFile;
  private readonly platform: PlatformServices;
  private readonly hooks: StoreHooks;
  private readonly ui: (event: UIEvent) => void;
  private readonly harnessFactory: NonNullable<AppStoreOptions["harnessFactory"]>;
  private readonly titleGenerator: NonNullable<AppStoreOptions["titleGenerator"]>;
  private readonly commitMessageGenerator: NonNullable<AppStoreOptions["commitMessageGenerator"]>;
  private readonly resolveExecutables: NonNullable<AppStoreOptions["resolveExecutables"]>;
  private readonly saveDelay: number;
  private readonly streamDelay: number;
  private resolved: { descriptors: HarnessDescriptor[]; codex: string | undefined } | undefined;
  private harnesses = new Map<string, AgentHarness>();
  private approvalResponders = new Map<string, (allow: boolean) => void>();
  private turnClocks = new Map<string, number>();
  private runIDs = new Map<string, string>();
  private titleRequests = new Map<string, string>();
  private titleAborts = new Map<string, AbortController>();
  private readyDrafts = new Set<string>();
  private saveTimer: NodeJS.Timeout | undefined;
  private streamTimer: NodeJS.Timeout | undefined;
  private pendingText = new Map<string, { role: ChatMessage["role"]; text: string }[]>();
  private pendingTextBytes = 0;
  private codexConfiguration = newID();
  private claudeConfiguration = newID();
  private shuttingDown = false;

  constructor(options: AppStoreOptions) {
    this.storage = options.storage;
    this.writer = new WorkspaceArchiveWriter(options.storage);
    this.preferences = options.preferences;
    this.platform = options.platform;
    this.hooks = { terminalTabCount: () => 0, closeBrowser: () => {}, applyTerminalTheme: () => {}, ...options.hooks };
    this.ui = options.ui ?? (() => {});
    this.harnessFactory = options.harnessFactory ?? ((id, codex) => HarnessRegistry.make(id, codex));
    this.titleGenerator = options.titleGenerator ?? ((id, text, codex) => defaultTitleGenerator(id, text, codex));
    this.commitMessageGenerator = options.commitMessageGenerator ?? ((model, changes, codex) => defaultCommitGenerator(model, changes, codex));
    this.resolveExecutables = options.resolveExecutables ?? (() => ({ descriptors: HarnessRegistry.descriptors(), codex: CodexExecutable.resolve() }));
    this.saveDelay = options.timing?.save ?? 350;
    this.streamDelay = options.timing?.stream ?? 33;
    const theme = this.preferences.get("theme");
    this.state = new StateStore<AppState>({
      archive: { schemaVersion: 1, projects: [] }, canSave: true,
      theme: isAppTheme(theme) ? theme : "system", systemDark: this.platform.systemDark(),
      codexExecutablePath: this.preferences.get("codexExecutablePath"), codexVersion: "Checking version…",
      descriptors: [], commitMessageModel: parseCommitModel(this.preferences.get("commitMessageModel") ?? ""),
      running: [], stopping: [], queued: {}, steering: {}, queueErrors: {}, pausedQueues: [], approvals: {}, interactions: {},
      drafts: {}, importingImages: [], modelCatalogs: {}, modelErrors: {}, loadingModels: [], commandCatalogs: {}, commandErrors: {},
      loadingCommands: [], checkingClaudeAuth: false, usageSnapshots: {}, usageErrors: {}, loadingUsage: [],
      openTarget: savedTarget(this.preferences.get("openTarget")),
    });
  }

  get s(): AppState { return this.state.state; }
  get archive(): WorkspaceArchive { return this.s.archive; }
  get project(): WorkspaceProject | undefined { return this.archive.projects.find((p) => p.id === this.archive.selectedProjectID); }
  get thread(): WorkspaceThread | undefined { return this.project?.threads.find((t) => t.id === this.archive.selectedThreadID); }
  isRunning(id: string): boolean { return this.s.running.includes(id); }
  private isStopping(id: string): boolean { return this.s.stopping.includes(id); }
  findThread(id: string): WorkspaceThread | undefined {
    for (const p of this.archive.projects) { const t = p.threads.find((t) => t.id === id); if (t) return t; }
    return undefined;
  }
  private setError(message: string): void { this.state.update((d) => { d.error = message; }); }
  dismissError(): void { this.state.update((d) => { delete d.error; }); }

  // MARK: Loading and saving

  async load(): Promise<void> {
    let archive: WorkspaceArchive | undefined;
    try {
      archive = await this.storage.load();
    } catch (error) {
      this.state.update((d) => { d.canSave = false; d.error = `Could not load workspace: ${(error as Error).message}\nThe existing file will not be overwritten.`; });
    }
    if (archive) {
      const loaded = archive;
      this.state.update((d) => {
        d.archive = loaded as Draft<WorkspaceArchive>;
        // Persisted activity is historical: a previous process cannot still own a live call.
        for (const project of d.archive.projects) for (const thread of project.threads) {
          if (thread.lastCompaction?.state === "compacting") { thread.lastCompaction.state = "interrupted"; thread.lastCompaction.endedAt = Date.now(); }
          for (const message of thread.messages) {
            if (message.toolActivity?.state === "running") { message.toolActivity.state = "interrupted"; message.text = toolActivityText(message.toolActivity); }
          }
        }
      });
    }
    this.refreshDescriptors();
    const thread = this.thread;
    if (this.archive.rememberedAgentSettings === undefined && thread) {
      this.state.update((d) => { d.archive.lastHarness = thread.harness; d.archive.rememberedAgentSettings = { [thread.harness]: { ...thread.agentSettings } }; });
    }
    if (this.s.canSave) {
      this.ensureChats();
      if (!this.project) await this.openChats();
      const current = this.thread;
      if (current && this.project?.isChatCollection) await this.prepareChat(current.id);
      this.saveSoon();
    }
    this.hooks.applyTerminalTheme(this.s.theme);
    void this.refreshCodexVersion();
  }

  private ensureChats(): void {
    if (!this.s.canSave || chatsProject(this.archive)) return;
    this.state.update((d) => {
      const chats = makeProject({ name: "Chats", rootPath: "" });
      chats.isChatCollection = true;
      d.archive.projects.push(chats as Draft<WorkspaceProject>);
    });
  }

  async openChats(): Promise<void> {
    this.ensureChats();
    const chats = chatsProject(this.archive);
    if (!chats) return;
    await this.selectProject(chats.id);
    if (!this.thread) await this.newThread({ projectID: chats.id });
  }

  async newChat(): Promise<void> {
    this.ensureChats();
    const chats = chatsProject(this.archive);
    if (chats) await this.newThread({ projectID: chats.id });
  }

  /** Chat directories prepared this session; later sends skip the filesystem round trip. */
  private preparedChats = new Map<string, string>();

  private async prepareChat(id: string): Promise<boolean> {
    if (!this.s.canSave) return false;
    const known = this.preparedChats.get(id);
    if (known !== undefined && chatsProject(this.archive)?.threads.find((t) => t.id === id)?.workingDirectory === known) return true;
    try {
      const directory = await this.storage.prepareChatDirectory(id);
      this.preparedChats.set(id, directory);
      if (chatsProject(this.archive)?.threads.find((t) => t.id === id)?.workingDirectory !== directory) this.mutate(id, (t) => { t.workingDirectory = directory; });
      return true;
    } catch (error) {
      this.setError(`Could not prepare chat: ${(error as Error).message}`);
      return false;
    }
  }

  saveSoon(): void {
    if (!this.s.canSave) return;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => { this.saveTimer = undefined; this.saveInBackground(); }, this.saveDelay);
  }

  private saveInBackground(): void {
    this.flushStreamText();
    if (!this.s.canSave) return;
    this.writer.write(this.archive, (error) => this.setError(`Could not save workspace: ${error.message}`));
  }

  /** Used on quit and by tests that read the file back. */
  async saveNow(): Promise<void> {
    if (this.saveTimer) { clearTimeout(this.saveTimer); this.saveTimer = undefined; }
    this.flushStreamText();
    if (!this.s.canSave) return;
    try { await this.writer.writeNow(this.archive); } catch (error) { this.setError(`Could not save workspace: ${(error as Error).message}`); }
  }

  // MARK: Executables and descriptors

  refreshDescriptors(): void {
    this.resolved = undefined;
    this.state.update((d) => { d.descriptors = this.harnessDescriptors() as Draft<HarnessDescriptor>[]; d.systemDark = this.platform.systemDark(); });
  }

  private executables(): { descriptors: HarnessDescriptor[]; codex: string | undefined } {
    if (!this.resolved) this.resolved = this.resolveExecutables();
    return this.resolved;
  }

  /** A custom path is a single stat and stays live, so a removed binary never silently falls back. */
  get codexExecutable(): string | undefined {
    const custom = this.s.codexExecutablePath;
    return custom !== undefined ? CodexExecutable.resolve(custom) : this.executables().codex;
  }

  harnessDescriptors(): HarnessDescriptor[] {
    return this.executables().descriptors.map((descriptor) => {
      const copy: HarnessDescriptor = { ...descriptor, capabilities: { ...descriptor.capabilities }, permissionOptions: [...descriptor.permissionOptions] };
      if (copy.id === "codex") {
        copy.executable = this.codexExecutable;
        if (!CodexHarness.supportsAutoReview(this.s.codexVersion)) {
          copy.permissionOptions = copy.permissionOptions.filter((o) => o.mode !== "autoReview");
          copy.capabilities.toolQuestions = false;
        }
      }
      return copy;
    });
  }

  private descriptor(id: HarnessID): HarnessDescriptor | undefined { return this.harnessDescriptors().find((d) => d.id === id); }
  supportsImages(id: HarnessID): boolean { return this.descriptor(id)?.supportsImages === true; }
  supportsModels(id: HarnessID): boolean { return this.descriptor(id)?.supportsModels === true; }

  private get codexIsRunning(): boolean {
    return this.archive.projects.some((p) => p.threads.some((t) => t.harness === "codex" && this.isRunning(t.id)));
  }

  async chooseCodexExecutable(): Promise<void> {
    const executable = this.codexExecutable;
    const path = await this.platform.chooseFile({ title: "Choose the Codex executable.", prompt: "Use Codex", defaultPath: executable });
    if (path) this.setCodexExecutable(path);
  }

  setCodexExecutable(path: string | undefined): void {
    if (this.codexIsRunning) { this.setError("Stop running Codex turns before changing its executable."); return; }
    if (path !== undefined && !CodexExecutable.executableAt(path)) { this.setError("Choose an executable file using an absolute path."); return; }
    // Idle connections must be recreated with the same binary used by discovery.
    for (const project of this.archive.projects) for (const thread of project.threads) {
      if (thread.harness !== "codex") continue;
      this.cancelTitle(thread.id);
      this.harnesses.get(thread.id)?.shutdown();
      this.harnesses.delete(thread.id);
    }
    this.preferences.set("codexExecutablePath", path);
    this.codexConfiguration = newID();
    this.state.update((d) => {
      if (path === undefined) delete d.codexExecutablePath; else d.codexExecutablePath = path;
      d.codexVersion = "Checking version…";
      d.modelCatalogs = {}; d.modelErrors = {}; d.loadingModels = [];
      d.commandCatalogs = {}; d.commandErrors = {}; d.loadingCommands = [];
      d.usageSnapshots = {}; d.usageErrors = {}; d.loadingUsage = [];
    });
    this.refreshDescriptors();
    void this.refreshCodexVersion();
  }

  async refreshCodexVersion(): Promise<void> {
    const configuration = this.codexConfiguration;
    const executable = this.codexExecutable;
    if (!executable) { this.state.update((d) => { d.codexVersion = "Executable not found"; }); this.refreshDescriptors(); return; }
    try {
      const version = await CodexExecutable.version(executable);
      if (configuration !== this.codexConfiguration) return;
      this.state.update((d) => { d.codexVersion = version || "Version unavailable"; });
    } catch (error) {
      if (configuration === this.codexConfiguration) this.state.update((d) => { d.codexVersion = `Version unavailable: ${(error as Error).message}`; });
    }
    this.refreshDescriptors();
  }

  async refreshClaudeAuth(): Promise<void> {
    if (this.s.checkingClaudeAuth) return;
    this.state.update((d) => { d.checkingClaudeAuth = true; delete d.claudeAuthError; });
    try {
      const executable = findExecutable("claude");
      if (!executable) throw new ProcessFailure("missing", "claude");
      const status = await ClaudeCLI.authStatus(executable);
      this.state.update((d) => { d.claudeAuth = status; });
    } catch (error) {
      this.state.update((d) => { delete d.claudeAuth; d.claudeAuthError = (error as Error).message; });
    } finally {
      this.state.update((d) => { d.checkingClaudeAuth = false; });
    }
  }

  /** After CLI sign-in closes, executables and Claude catalogs are rediscovered. */
  claudeSetupClosed(): void {
    this.refreshDescriptors();
    this.claudeConfiguration = newID();
    const keep = <T>(record: Record<string, T>) => Object.fromEntries(Object.entries(record).filter(([k]) => !k.startsWith("claude:")));
    this.state.update((d) => {
      d.commandCatalogs = keep(d.commandCatalogs); d.commandErrors = keep(d.commandErrors);
      d.loadingCommands = d.loadingCommands.filter((k) => !k.startsWith("claude:"));
      d.modelCatalogs = keep(d.modelCatalogs); d.modelErrors = keep(d.modelErrors);
      d.loadingModels = d.loadingModels.filter((k) => !k.startsWith("claude:"));
    });
    void this.refreshClaudeAuth();
  }

  setTheme(theme: AppTheme): void {
    this.preferences.set("theme", theme);
    this.state.update((d) => { d.theme = theme; });
    this.hooks.applyTerminalTheme(theme);
  }

  setSystemDark(dark: boolean): void {
    if (this.s.systemDark !== dark) this.state.update((d) => { d.systemDark = dark; });
  }

  setOpenTarget(target: string): void {
    this.preferences.set("openTarget", target);
    this.state.update((d) => { d.openTarget = target; });
  }

  // MARK: Projects and threads

  async chooseProject(): Promise<void> {
    const path = await this.platform.chooseDirectory({ title: "Choose a local Git repository.", prompt: "Add Project" });
    if (path) await this.addProject(path);
  }

  async addProject(path: string, repositoryRoot?: (path: string) => Promise<string>): Promise<void> {
    try {
      const root = await (repositoryRoot ?? ((p: string) => new GitService().repositoryRoot(p)))(path);
      const existing = this.archive.projects.find((p) => p.rootPath === root);
      if (existing) { await this.selectProject(existing.id); return; }
      const project = makeProject({ name: basename(root), rootPath: root });
      this.state.update((d) => { d.archive.projects.push(project as Draft<WorkspaceProject>); });
      await this.selectProject(project.id);
      await this.newThread();
    } catch (error) {
      this.setError(`Could not add project: ${(error as Error).message}`);
    }
  }

  async selectProject(id: string): Promise<void> {
    const current = this.archive.projects.find((p) => p.id === id);
    if (!current) return;
    // Re-selecting the current project should not jump away from its thread.
    const selected = current.threads.find((t) => t.id === this.archive.selectedThreadID) ?? orderedThreads(current)[0];
    if (current.isChatCollection && selected && !(await this.prepareChat(selected.id))) return;
    this.state.update((d) => {
      const project = d.archive.projects.find((p) => p.id === id)!;
      project.isCollapsed = false;
      d.archive.selectedProjectID = id;
      d.archive.selectedThreadID = selected?.id;
    });
    if (selected) this.mutate(selected.id, (t) => { t.lastVisitedAt = Date.now(); });
    this.saveSoon();
  }

  async selectThread(threadID: string, projectID: string): Promise<void> {
    const owner = this.archive.projects.find((p) => p.id === projectID);
    if (!owner?.threads.some((t) => t.id === threadID)) return;
    if (owner.isChatCollection && !(await this.prepareChat(threadID))) return;
    this.mutate(threadID, (t) => { t.lastVisitedAt = Date.now(); });
    this.state.update((d) => { d.archive.selectedProjectID = projectID; d.archive.selectedThreadID = threadID; });
    this.saveSoon();
  }

  /** Selects a project for its terminal workspace, keeping one of its threads selected behind it. */
  openTerminal(projectID: string): boolean {
    const project = this.archive.projects.find((p) => p.id === projectID);
    if (!project || project.isChatCollection) return false;
    this.state.update((d) => {
      d.archive.selectedProjectID = projectID;
      if (!project.threads.some((t) => t.id === d.archive.selectedThreadID)) d.archive.selectedThreadID = orderedThreads(project)[0]?.id;
    });
    this.saveSoon();
    return true;
  }

  /** Called only when the active chat is visible and following its latest output. */
  markThreadRead(id: string): void {
    if (this.thread?.id !== id || this.thread.unreadCompletedAt === undefined) return;
    this.mutate(id, (t) => { delete t.unreadCompletedAt; });
  }

  private rememberedSettings(harness: HarnessID): AgentSettings {
    return this.archive.rememberedAgentSettings?.[harness] ?? (this.thread?.harness === harness ? this.thread.agentSettings : undefined) ?? {};
  }

  private rememberAgentChoices(): void {
    const thread = this.thread;
    if (!thread) return;
    this.state.update((d) => {
      d.archive.lastHarness = thread.harness;
      d.archive.rememberedAgentSettings ??= {};
      d.archive.rememberedAgentSettings[thread.harness] = { ...thread.agentSettings };
    });
    this.saveSoon();
  }

  private hasDraft(id: string): boolean {
    const draft = this.s.drafts[id];
    return this.readyDrafts.has(id) || (draft !== undefined && (draft.images.length > 0 || draft.code.length > 0 || draft.annotations.length > 0));
  }

  async newThread(options: { harness?: HarnessID; projectID?: string } = {}): Promise<void> {
    if (!this.s.canSave) return;
    if (options.projectID === undefined && !this.project) {
      this.ensureChats();
      const chats = chatsProject(this.archive);
      this.state.update((d) => { d.archive.selectedProjectID = chats?.id; });
    }
    const projectID = options.projectID ?? this.archive.selectedProjectID;
    const project = this.archive.projects.find((p) => p.id === projectID);
    if (!project) return;
    const harness = options.harness ?? this.archive.lastHarness ?? this.thread?.harness ?? "codex";
    const settings = this.rememberedSettings(harness);
    // Reopen the project's unfinished composer, including text and attachments. Existing duplicate
    // drafts remain intact; this action never creates more.
    const candidates = project.threads.filter((t) => t.messages.length === 0 && t.remoteSessionID === undefined && !this.isRunning(t.id));
    const existing = candidates.find((t) => t.id === this.archive.selectedThreadID) ?? candidates[candidates.length - 1];
    let id: string;
    if (existing) {
      id = existing.id;
      if (project.isChatCollection && !(await this.prepareChat(id))) return;
      if (options.harness !== undefined || !this.hasDraft(id)) this.mutate(id, (t) => { t.harness = harness; t.agentSettings = { ...settings }; });
    } else {
      const thread = makeThread({ harness, workingDirectory: project.rootPath });
      if (project.isChatCollection) {
        thread.title = "New chat";
        try { thread.workingDirectory = await this.storage.prepareChatDirectory(thread.id); }
        catch (error) { this.setError(`Could not prepare chat: ${(error as Error).message}`); return; }
      }
      thread.agentSettings = { ...settings };
      this.state.update((d) => { d.archive.projects.find((p) => p.id === project.id)!.threads.push(thread as Draft<WorkspaceThread>); });
      id = thread.id;
    }
    this.state.update((d) => {
      d.archive.projects.find((p) => p.id === project.id)!.isCollapsed = false;
      d.archive.selectedProjectID = project.id;
      d.archive.selectedThreadID = id;
    });
    this.saveSoon();
  }

  private updateProject(id: string, change: (project: Draft<WorkspaceProject>) => void, includeChats = false): void {
    this.state.update((d) => {
      const project = d.archive.projects.find((p) => p.id === id && (includeChats || !p.isChatCollection));
      if (project) change(project);
    });
    this.saveSoon();
  }

  toggleProjectPin(id: string): void { this.updateProject(id, (p) => { p.isPinned = !p.isPinned; }); }
  toggleProjectCollapse(id: string): void { this.updateProject(id, (p) => { p.isCollapsed = !p.isCollapsed; }, true); }
  toggleProjectsSection(): void { this.state.update((d) => { d.archive.projectsSectionCollapsed = !(d.archive.projectsSectionCollapsed ?? false); }); this.saveSoon(); }
  toggleRecentSection(): void { this.state.update((d) => { d.archive.recentSectionCollapsed = !(d.archive.recentSectionCollapsed ?? false); }); this.saveSoon(); }
  toggleThreadPin(id: string): void { this.mutate(id, (t) => { t.isPinned = !t.isPinned; }); }

  renameProject(id: string, name: string): void {
    const trimmed = name.trim();
    if (trimmed) this.updateProject(id, (p) => { p.name = trimmed; });
  }

  renameThread(id: string, title: string): void {
    const trimmed = title.trim();
    if (!trimmed) return;
    this.cancelTitle(id);
    this.mutate(id, (t) => { t.title = trimmed; t.isTitleManuallySet = true; });
  }

  deleteThread(id: string, projectID: string): void {
    if (this.isRunning(id)) { this.setError("Stop the running agent before deleting this thread."); return; }
    this.cancelTitle(id);
    this.harnesses.get(id)?.shutdown();
    this.harnesses.delete(id);
    this.readyDrafts.delete(id);
    this.state.update((d) => {
      delete d.queued[id]; toggleIn(d.pausedQueues, id, false); delete d.drafts[id]; delete d.approvals[id]; delete d.interactions[id];
      removeArchiveThread(d.archive as WorkspaceArchive, id, projectID);
    });
    this.saveSoon();
  }

  removeProject(id: string): void {
    const project = this.archive.projects.find((p) => p.id === id && !p.isChatCollection);
    if (!project) return;
    if (project.threads.some((t) => this.isRunning(t.id)) || this.hooks.terminalTabCount(id) > 0) {
      this.setError("Stop this project's agents and close its terminal tabs before removing it."); return;
    }
    for (const thread of project.threads) this.deleteThread(thread.id, id);
    this.state.update((d) => { removeArchiveProject(d.archive as WorkspaceArchive, id); });
    for (const tab of project.panelTabs.tabs) if (tab.kind === "browser") this.hooks.closeBrowser(tab.id);
    this.saveSoon();
  }

  async changeHarness(harness: HarnessID): Promise<void> {
    const thread = this.thread;
    if (!thread || this.isRunning(thread.id) || thread.harness === harness) return;
    this.rememberAgentChoices();
    if (thread.messages.length === 0 && thread.remoteSessionID === undefined) {
      const settings = this.rememberedSettings(harness);
      this.mutate(thread.id, (t) => { t.harness = harness; t.agentSettings = { ...settings }; });
    } else {
      await this.newThread({ harness });
    }
    this.rememberAgentChoices();
  }

  // MARK: Catalogs

  modelKey(harness: HarnessID, directory: string): string { return `${harness}:${directory}`; }
  private configuration(harness: HarnessID): string { return harness === "claude" ? this.claudeConfiguration : this.codexConfiguration; }

  async loadModels(directory: string, harness: HarnessID = "codex", refresh = false): Promise<void> {
    const key = this.modelKey(harness, directory);
    if (!this.supportsModels(harness) || this.s.loadingModels.includes(key) || (!refresh && this.s.modelCatalogs[key])) return;
    const configuration = this.configuration(harness);
    this.state.update((d) => { toggleIn(d.loadingModels, key, true); delete d.modelErrors[key]; });
    try {
      if (harness === "codex" && !this.codexExecutable) throw new ProcessFailure("missing", "Codex executable (choose one in Settings)");
      const models = await HarnessRegistry.models(harness, directory, this.codexExecutable);
      if (configuration !== this.configuration(harness)) return;
      this.state.update((d) => { d.modelCatalogs[key] = models; });
    } catch (error) {
      if (configuration === this.configuration(harness)) this.state.update((d) => { d.modelErrors[key] = `Could not load ${harnessTitle(harness)} models: ${(error as Error).message}`; });
    } finally {
      if (configuration === this.configuration(harness)) this.state.update((d) => { toggleIn(d.loadingModels, key, false); });
    }
  }

  async loadCommands(threadID: string, refresh = false): Promise<void> {
    const thread = this.findThread(threadID);
    if (!thread) return;
    const key = this.modelKey(thread.harness, thread.workingDirectory), configuration = this.configuration(thread.harness);
    if (this.s.loadingCommands.includes(key) || (!refresh && this.s.commandCatalogs[key])) return;
    this.state.update((d) => { toggleIn(d.loadingCommands, key, true); delete d.commandErrors[key]; });
    try {
      const commands = await HarnessRegistry.commands(thread.harness, thread.workingDirectory, this.codexExecutable);
      if (configuration !== this.configuration(thread.harness)) return;
      this.state.update((d) => { d.commandCatalogs[key] = commands; });
    } catch (error) {
      if (configuration === this.configuration(thread.harness)) this.state.update((d) => { d.commandErrors[key] = (error as Error).message; });
    } finally {
      if (configuration === this.configuration(thread.harness)) this.state.update((d) => { toggleIn(d.loadingCommands, key, false); });
    }
  }

  private catalogModel(thread: WorkspaceThread, model: string): AgentModel | undefined {
    return this.s.modelCatalogs[this.modelKey(thread.harness, thread.workingDirectory)]?.find((m) => m.model === model);
  }

  selectModel(model: string): void {
    const thread = this.thread;
    if (!thread || !this.supportsModels(thread.harness) || this.isRunning(thread.id)) return;
    const found = this.catalogModel(thread, model);
    if (found) this.applyModel(found, thread.id);
  }

  /** Chooses a provider and optionally one of its models. A provider change on a thread with history starts a new thread. */
  async selectAgent(harness: HarnessID, model: string | undefined): Promise<void> {
    const current = this.thread;
    if (!current || this.isRunning(current.id)) return;
    if (current.harness !== harness) await this.changeHarness(harness);
    const thread = this.thread;
    if (model === undefined || !thread || thread.harness !== harness || !this.supportsModels(harness)) return;
    const found = this.catalogModel(thread, model);
    if (found) this.applyModel(found, thread.id);
  }

  private applyModel(model: AgentModel, threadID: string): void {
    this.mutate(threadID, (t) => {
      const previous = t.agentSettings.reasoningEffort;
      const fallback = model.defaultReasoningEffort || undefined;
      const effort = model.supportedReasoningEfforts.some((e) => e.reasoningEffort === previous) ? previous : fallback;
      t.agentSettings = { model: model.model, ...(effort !== undefined ? { reasoningEffort: effort } : {}), ...(t.agentSettings.permissionMode ? { permissionMode: t.agentSettings.permissionMode } : {}) };
    });
    this.rememberAgentChoices();
  }

  selectReasoning(effort: string): void {
    const thread = this.thread;
    if (!thread || !this.supportsModels(thread.harness) || this.isRunning(thread.id) || !thread.agentSettings.model) return;
    const model = this.catalogModel(thread, thread.agentSettings.model);
    if (!model?.supportedReasoningEfforts.some((e) => e.reasoningEffort === effort)) return;
    this.mutate(thread.id, (t) => { t.agentSettings.reasoningEffort = effort; });
    this.rememberAgentChoices();
  }

  selectPermissions(mode: AgentPermissionMode, threadID: string): void {
    const thread = this.thread;
    if (!thread || thread.id !== threadID || this.isRunning(thread.id) || !this.descriptor(thread.harness)?.permissionOptions.some((o) => o.mode === mode)) return;
    this.mutate(thread.id, (t) => { t.agentSettings.permissionMode = mode; });
    this.rememberAgentChoices();
  }

  // MARK: Commit messages

  selectCommitMessageModel(model: CommitMessageModel | undefined): void {
    this.preferences.set("commitMessageModel", model ? commitModelStorageValue(model) : undefined);
    this.state.update((d) => { if (model) d.commitMessageModel = model; else delete d.commitMessageModel; });
  }

  automaticCommitModels(directory: string): CommitMessageModel[] {
    const installed = new Set(this.harnessDescriptors().filter((d) => d.supportsModels && d.executable).map((d) => d.id));
    const catalogs: Partial<Record<HarnessID, AgentModel[]>> = {};
    for (const id of installed) { const catalog = this.s.modelCatalogs[this.modelKey(id, directory)]; if (catalog?.length) catalogs[id] = catalog; }
    return automaticCommitModels(installed, catalogs);
  }

  async loadCommitMessageModels(directory: string): Promise<void> {
    const installed = this.harnessDescriptors().filter((d) => d.supportsModels && d.executable).map((d) => d.id);
    await Promise.all(installed.map((id) => this.loadModels(directory, id)));
  }

  generateCommitMessage(model: CommitMessageModel, changes: StagedChanges): Promise<string> {
    return this.commitMessageGenerator(model, changes, this.codexExecutable);
  }

  // MARK: Usage

  /** Claude limits arrive on any session's stream and belong to the signed-in account, not a checkout. */
  usageKey(thread: Pick<WorkspaceThread, "harness" | "workingDirectory">): string {
    return thread.harness === "claude" ? thread.harness : `${thread.harness}:${thread.workingDirectory}`;
  }

  /** The thread whose checkout read-only limit queries run in: the selected one, else the newest using the provider. */
  usageThread(provider: HarnessID): WorkspaceThread | undefined {
    const thread = this.thread;
    if (thread?.harness === provider) return thread;
    let newest: WorkspaceThread | undefined;
    for (const p of this.archive.projects) for (const t of p.threads) if (t.harness === provider && (!newest || t.createdAt > newest.createdAt)) newest = t;
    return newest;
  }

  async loadUsage(provider: HarnessID): Promise<void> {
    const thread = this.usageThread(provider);
    if (!thread) return;
    const key = this.usageKey(thread), configuration = this.codexConfiguration;
    if (this.s.loadingUsage.includes(key)) return;
    this.state.update((d) => { toggleIn(d.loadingUsage, key, true); delete d.usageErrors[key]; });
    try {
      if (thread.harness === "codex" && !this.codexExecutable) throw new ProcessFailure("missing", "Codex executable");
      const usage = await HarnessRegistry.usage(thread.harness, thread.workingDirectory, this.codexExecutable);
      if (configuration === this.codexConfiguration) this.state.update((d) => { d.usageSnapshots[key] = usage; });
    } catch (error) {
      if (configuration === this.codexConfiguration) this.state.update((d) => { d.usageErrors[key] = `Usage unavailable: ${(error as Error).message}`; });
    } finally {
      if (configuration === this.codexConfiguration) this.state.update((d) => { toggleIn(d.loadingUsage, key, false); });
    }
  }

  // MARK: Draft attachments

  private updateDraft(id: string, change: (draft: Draft<DraftAttachments>) => void): void {
    this.state.update((d) => {
      d.drafts[id] ??= { images: [], code: [], annotations: [] };
      change(d.drafts[id]);
    });
  }

  draft(id: string): DraftAttachments { return this.s.drafts[id] ?? EMPTY_DRAFT; }

  /** The renderer reports when draft text becomes nonempty or empty. Starting a draft is activity for Recent. */
  setDraftReady(id: string, ready: boolean): void {
    if (ready === this.readyDrafts.has(id)) return;
    if (ready) { this.readyDrafts.add(id); this.mutate(id, (t) => { t.lastDraftedAt = Date.now(); }); }
    else this.readyDrafts.delete(id);
  }

  private canAttachImage(threadID: string): boolean {
    const owner = this.findThread(threadID);
    if (!owner) return false;
    if (!this.supportsImages(owner.harness)) { this.setError("Image attachments are unavailable with this provider."); return false; }
    if (this.draft(threadID).images.length >= 4) { this.setError("You can attach up to four images per message."); return false; }
    return true;
  }

  /** True when the clipboard holds an image, even if rejected, so it never falls through to a text paste. */
  async pasteImage(threadID: string): Promise<boolean> {
    const data = await this.platform.clipboardImage();
    if (!data) return false;
    if (!this.canAttachImage(threadID)) return true;
    try {
      const image = this.platform.decodeImage(data, "Screenshot");
      this.updateDraft(threadID, (d) => { d.images.push(image); });
    } catch (error) { this.setError((error as Error).message); }
    return true;
  }

  async chooseImages(threadID: string): Promise<void> {
    if (this.s.importingImages.includes(threadID) || !this.canAttachImage(threadID)) return;
    const paths = await this.platform.chooseImages();
    await this.importImages(paths, threadID);
  }

  async importImages(paths: string[], threadID: string): Promise<void> {
    if (paths.length === 0 || this.s.importingImages.includes(threadID) || !this.canAttachImage(threadID)) return;
    if (paths.length + this.draft(threadID).images.length > 4) { this.setError("You can attach up to four images per message. Choose fewer files."); return; }
    this.state.update((d) => { toggleIn(d.importingImages, threadID, true); });
    try {
      for (const path of paths) {
        let image: ImageAttachment;
        try { image = await this.platform.readImageFile(path); }
        catch (error) { this.setError(`${basename(path)}: ${(error as Error).message}`); continue; }
        // Navigation, deletion and provider changes may occur while decoding.
        if (!this.canAttachImage(threadID)) return;
        this.updateDraft(threadID, (d) => { d.images.push(image); });
      }
    } finally {
      this.state.update((d) => { toggleIn(d.importingImages, threadID, false); });
    }
  }

  removeDraftImage(threadID: string, id: string): void { this.updateDraft(threadID, (d) => { d.images = d.images.filter((i) => i.id !== id); }); }
  removeDraftCode(threadID: string, id: string): void { this.updateDraft(threadID, (d) => { d.code = d.code.filter((i) => i.id !== id); }); }
  removeDraftAnnotation(threadID: string, id: string): void { this.updateDraft(threadID, (d) => { d.annotations = d.annotations.filter((i) => i.id !== id); }); }

  async attach(attachment: CodeAttachment): Promise<void> {
    const project = this.project;
    if (!project || project.id !== attachment.projectID) return;
    if (!this.thread) await this.newThread();
    const thread = this.thread;
    if (!thread || thread.workingDirectory !== attachment.workingDirectory) { this.setError("This selection belongs to a different checkout."); return; }
    this.updateDraft(thread.id, (d) => { d.code.push(attachment as Draft<CodeAttachment>); });
    this.ui({ type: "showThread" });
  }

  /** Adds an annotation (and its screenshot when the provider accepts images) to the draft; never sends. */
  async attachBrowserAnnotation(annotation: BrowserAnnotation, screenshot: Buffer | undefined, projectID: string): Promise<void> {
    if (this.project?.id !== projectID || this.shuttingDown) return;
    if (!this.thread) await this.newThread();
    const thread = this.thread;
    if (!thread) return;
    const captured = { ...annotation };
    const draft = this.draft(thread.id);
    if (screenshot && this.supportsImages(thread.harness) && draft.images.length < 4) {
      try {
        const image = this.platform.decodeImage(screenshot, `Annotation ${draft.annotations.length + 1}`);
        this.updateDraft(thread.id, (d) => { d.images.push(image); });
        captured.screenshot = image.name;
      } catch { /* the annotation still attaches without its image */ }
    }
    this.updateDraft(thread.id, (d) => { d.annotations.push(captured as Draft<BrowserAnnotation>); });
    this.ui({ type: "focusComposer" });
  }

  async attachBrowserScreenshot(data: Buffer, projectID: string): Promise<void> {
    if (this.project?.id !== projectID || this.shuttingDown) return;
    if (!this.thread) await this.newThread();
    const thread = this.thread;
    if (!thread || !this.canAttachImage(thread.id)) return;
    try {
      const image = this.platform.decodeImage(data, "Browser");
      this.updateDraft(thread.id, (d) => { d.images.push(image); });
      this.ui({ type: "focusComposer" });
    } catch (error) { this.setError((error as Error).message); }
  }

  // MARK: Panel tabs

  updatePanelTabs(projectID: string, change: (tabs: PanelTabs) => void): void {
    this.state.update((d) => {
      const project = d.archive.projects.find((p) => p.id === projectID && !p.isChatCollection);
      if (project) change(project.panelTabs as PanelTabs);
    });
    this.saveSoon();
  }

  /** Panel tab edits requested by the renderer. Closing a browser tab also closes its page. */
  updatePanelTabsAction(projectID: string, operation: PanelTabOperation): void {
    this.updatePanelTabs(projectID, (tabs) => applyPanelTabOperation(tabs, operation));
    if (operation.type === "close" && operation.tab.kind === "browser") this.hooks.closeBrowser(operation.tab.id);
  }

  // MARK: Sending

  canSend(threadID: string, text: string): boolean {
    return !this.s.importingImages.includes(threadID) && (text.trim().length > 0 || this.draft(threadID).images.length > 0);
  }

  private validateMessage(thread: WorkspaceThread, images: ImageAttachment[]): string | undefined {
    this.resolved = undefined;
    const descriptor = this.descriptor(thread.harness);
    const mode = thread.agentSettings.permissionMode;
    if (mode && !descriptor?.permissionOptions.some((o) => o.mode === mode)) return "The saved permission mode is unavailable with this CLI. Choose a supported mode before sending.";
    if (images.length > 0) {
      if (!this.supportsImages(thread.harness)) return "Screenshot attachments are unavailable with this provider. Remove them or switch providers.";
      const model = thread.agentSettings.model ? this.catalogModel(thread, thread.agentSettings.model) : undefined;
      if (model && !modelSupportsImages(model)) return "This model does not support images. Choose an image-capable model or remove the screenshots.";
    }
    if (thread.harness === "codex" && !this.codexExecutable) return "Codex executable not found. Choose an installation in Settings.";
    if (!descriptor?.executable) return `${harnessTitle(thread.harness)} executable not found. Install its CLI and authenticate before sending.`;
    const catalog = this.s.modelCatalogs[this.modelKey(thread.harness, thread.workingDirectory)];
    if (this.supportsModels(thread.harness) && thread.agentSettings.model && catalog) {
      const model = catalog.find((m) => m.model === thread.agentSettings.model);
      if (!model) return "The selected model is unavailable. Choose a model from the current catalog.";
      const effort = thread.agentSettings.reasoningEffort;
      if (effort && effort !== model.defaultReasoningEffort && !model.supportedReasoningEfforts.some((e) => e.reasoningEffort === effort)) {
        return "The selected reasoning effort is unavailable for this model. Choose a supported effort.";
      }
    }
    return undefined;
  }

  /** Sends the draft explicitly; while a turn runs, it queues (up to 20). Returns true when the draft was taken. */
  async send(threadID: string, rawText: string): Promise<boolean> {
    if (this.project?.isChatCollection && this.thread?.id === threadID && !(await this.prepareChat(threadID))) return false;
    const thread = this.findThread(threadID);
    if (!thread || !this.canSend(threadID, rawText) || this.shuttingDown) return false;
    const draft = this.draft(threadID);
    const failure = this.validateMessage(thread, draft.images);
    if (failure) { this.setError(failure); return false; }
    if ((this.s.queued[threadID]?.length ?? 0) >= 20) { this.setError("You can queue up to 20 messages per chat."); return false; }
    const message = makeMessage("user", rawText.trim(), { attachments: [...draft.code], images: [...draft.images], browserAnnotations: [...draft.annotations] });
    const queued: QueuedMessage = { id: message.id, message, harness: thread.harness, directory: thread.workingDirectory };
    this.readyDrafts.delete(threadID);
    this.state.update((d) => {
      d.drafts[threadID] = { images: [], code: [], annotations: [] };
      if (!d.running.includes(threadID) && (d.queued[threadID] ?? []).length === 0) toggleIn(d.pausedQueues, threadID, false);
      (d.queued[threadID] ??= []).push(queued as Draft<QueuedMessage>);
    });
    if (!this.isRunning(threadID) && !this.s.pausedQueues.includes(threadID)) this.sendNextQueued(threadID);
    return true;
  }

  canSteer(threadID: string): boolean {
    const thread = this.findThread(threadID);
    return !!thread && this.isRunning(threadID) && !this.isStopping(threadID) && this.s.steering[threadID] === undefined &&
      this.descriptor(thread.harness)?.capabilities.steering === true;
  }

  removeQueued(messageID: string, threadID: string): void {
    if (this.s.steering[threadID] === messageID) return;
    this.state.update((d) => {
      d.queued[threadID] = (d.queued[threadID] ?? []).filter((q) => q.id !== messageID);
      delete d.queueErrors[messageID];
      if (d.queued[threadID].length === 0) toggleIn(d.pausedQueues, threadID, false);
    });
  }

  resumeQueue(threadID: string): void {
    if (this.isRunning(threadID) || this.s.steering[threadID] !== undefined) return;
    this.state.update((d) => { toggleIn(d.pausedQueues, threadID, false); });
    this.sendNextQueued(threadID);
  }

  private sendNextQueued(id: string): void {
    const queued = this.s.queued[id]?.[0];
    const thread = this.findThread(id);
    if (this.shuttingDown || this.isRunning(id) || this.s.steering[id] !== undefined || this.s.pausedQueues.includes(id) || !queued || !thread) return;
    if (queued.harness !== thread.harness || queued.directory !== thread.workingDirectory) {
      this.state.update((d) => { toggleIn(d.pausedQueues, id, true); d.queueErrors[queued.id] = "The provider or checkout changed. Remove this message and compose it again."; });
      return;
    }
    const failure = this.validateMessage(thread, queued.message.images);
    if (failure) {
      this.state.update((d) => { toggleIn(d.pausedQueues, id, true); d.queueErrors[queued.id] = failure; d.error = failure; });
      return;
    }
    this.state.update((d) => { d.queued[id].shift(); delete d.queueErrors[queued.id]; });
    this.prepareThreadTitle(thread, queued.message.text);
    this.flushStreamText();
    this.mutate(id, (t) => { t.messages.push(queued.message as Draft<ChatMessage>); });
    this.beginWork(id);
    let harness = this.harnesses.get(id);
    if (!harness) {
      harness = this.harnessFactory(thread.harness, this.codexExecutable);
      this.harnesses.set(id, harness);
      harness.onEvent = (event) => this.receive(event, id);
    }
    const runID = this.runIDs.get(id);
    const current = this.findThread(id)!;
    const active = harness;
    setImmediate(async () => {
      if (this.shuttingDown || this.runIDs.get(id) !== runID) return;
      if (this.isStopping(id)) { this.receive({ type: "interrupted" }, id); return; }
      try {
        await active.send(queuedPrompt(queued.message), current.remoteSessionID, queued.directory, current.agentSettings, queued.message.images);
      } catch (error) {
        if (this.runIDs.get(id) === runID) this.receive({ type: "failed", text: (error as Error).message }, id);
      }
    });
  }

  async steerQueued(messageID: string, threadID: string): Promise<void> {
    const queued = this.s.queued[threadID]?.find((q) => q.id === messageID);
    const harness = this.harnesses.get(threadID);
    if (!this.canSteer(threadID) || !queued || !harness) return;
    this.flushStreamText();
    const insertionIndex = this.findThread(threadID)?.messages.length ?? 0;
    this.state.update((d) => { d.steering[threadID] = messageID; delete d.queueErrors[messageID]; });
    try {
      await harness.steer(queuedPrompt(queued.message), queued.message.images);
      if (this.shuttingDown) return;
      this.flushStreamText();
      this.mutate(threadID, (t) => { t.messages.splice(Math.min(insertionIndex, t.messages.length), 0, { ...queued.message, isSteering: true } as Draft<ChatMessage>); });
      this.state.update((d) => { d.queued[threadID] = (d.queued[threadID] ?? []).filter((q) => q.id !== messageID); });
    } catch (error) {
      if (this.shuttingDown) return;
      this.state.update((d) => { d.queueErrors[messageID] = `Steering was not confirmed: ${(error as Error).message}`; toggleIn(d.pausedQueues, threadID, true); });
    }
    this.state.update((d) => { delete d.steering[threadID]; });
    this.sendNextQueued(threadID);
  }

  /** Called only on explicit send; opening saved chats never makes a title request. */
  private prepareThreadTitle(thread: WorkspaceThread, text: string): void {
    if (thread.messages.length > 0 || !["New thread", "New chat"].includes(thread.title) || thread.isTitleManuallySet) return;
    const fallback = text ? Array.from(text).slice(0, 52).join("") : "Screenshot discussion";
    this.mutate(thread.id, (t) => { t.title = fallback; });
    if (!text || !TITLE_CONFIGURATIONS[thread.harness]) return;
    this.cancelTitle(thread.id);
    const request = newID(), abort = new AbortController();
    this.titleRequests.set(thread.id, request);
    this.titleAborts.set(thread.id, abort);
    void this.titleGenerator(thread.harness, Array.from(text).slice(0, 4_000).join(""), this.codexExecutable)
      .catch(() => undefined)
      .then((result) => {
        if (abort.signal.aborted || this.shuttingDown || this.titleRequests.get(thread.id) !== request) return;
        this.titleRequests.delete(thread.id); this.titleAborts.delete(thread.id);
        const title = result ? ThreadTitles.validated(result) : undefined;
        if (!title) return;
        this.mutate(thread.id, (t) => {
          if (t.isTitleManuallySet || t.title !== fallback || t.harness !== thread.harness) return;
          t.title = title;
        });
      });
  }

  private cancelTitle(id: string): void {
    this.titleRequests.delete(id);
    this.titleAborts.get(id)?.abort();
    this.titleAborts.delete(id);
  }

  /** Replaces the whole archive, for imports and tests. */
  replaceArchive(archive: WorkspaceArchive): void {
    this.state.update((d) => { d.archive = archive as Draft<WorkspaceArchive>; });
    this.saveSoon();
  }

  beginWork(id: string): void {
    if (this.isRunning(id)) return;
    this.runIDs.set(id, newID());
    this.turnClocks.set(id, performance.now());
    this.state.update((d) => { toggleIn(d.stopping, id, false); toggleIn(d.running, id, true); });
    this.mutate(id, (t) => {
      t.lastActivityAt = Date.now();
      for (let i = t.messages.length - 1; i >= 0; i--) {
        if (t.messages[i].role === "user") { t.messages[i].work = { startedAt: Date.now() }; break; }
      }
    });
  }

  private finishWork(id: string, outcome: NonNullable<TurnWork["outcome"]>): void {
    this.endCompaction(id);
    this.endToolActivities(id);
    const started = this.turnClocks.get(id);
    if (started === undefined) return;
    this.turnClocks.delete(id);
    this.runIDs.delete(id);
    const elapsed = Math.max(0, (performance.now() - started) / 1000), completed = Date.now();
    const result = this.isStopping(id) ? "stopped" : outcome;
    this.state.update((d) => { toggleIn(d.stopping, id, false); });
    this.mutate(id, (t) => {
      t.lastActivityAt = completed;
      if (result === "completed") t.unreadCompletedAt = completed;
      let index = -1;
      for (let i = t.messages.length - 1; i >= 0; i--) if (t.messages[i].role === "user" && t.messages[i].work) { index = i; break; }
      if (index === -1) return;
      t.messages[index].work!.elapsed = elapsed;
      t.messages[index].work!.outcome = result;
      for (let i = index + 1; i < t.messages.length; i++) if (t.messages[i].role === "assistant") t.messages[i].completedAt = completed;
    });
  }

  stop(id: string): void {
    this.cancelTitle(id);
    if (!this.isRunning(id)) return;
    this.flushStreamText();
    this.endCompaction(id);
    this.state.update((d) => { toggleIn(d.stopping, id, true); toggleIn(d.pausedQueues, id, true); d.interactions[id] = []; d.approvals[id] = []; });
    this.endToolActivities(id);
    const runID = this.runIDs.get(id), harness = this.harnesses.get(id);
    setImmediate(() => {
      if (this.runIDs.get(id) !== runID || !this.isStopping(id)) return;
      void harness?.interrupt();
    });
  }

  private endToolActivities(id: string): void {
    const thread = this.findThread(id);
    if (!thread?.messages.some((m) => m.toolActivity?.state === "running")) return;
    this.mutate(id, (t) => {
      for (const message of t.messages) {
        if (message.toolActivity?.state !== "running") continue;
        message.toolActivity.state = "interrupted";
        message.text = toolActivityText(message.toolActivity);
      }
    });
  }

  private endCompaction(id: string): void {
    if (this.findThread(id)?.lastCompaction?.state !== "compacting") return;
    this.mutate(id, (t) => { t.lastCompaction!.state = "interrupted"; t.lastCompaction!.endedAt = Date.now(); });
  }

  /**
   * Coalesces streamed text from all chats into one publication per 33 ms (or 64 KiB). Protocol
   * boundaries stay immediate and flush text first, preserving order.
   */
  receive(event: AgentEvent, threadID: string): void {
    let role: ChatMessage["role"];
    let text: string;
    switch (event.type) {
      case "textDelta": role = "assistant"; text = event.text; break;
      case "activityDelta": role = "activity"; text = event.text; break;
      case "reasoningDelta": role = "reasoning"; text = event.text; break;
      default:
        this.flushStreamText();
        this.handle(event, threadID);
        return;
    }
    if (!this.isRunning(threadID) || this.isStopping(threadID) || !text) return;
    const bytes = Buffer.byteLength(text);
    if (this.pendingTextBytes + bytes > STREAM_BYTES) this.flushStreamText();
    const chunks = this.pendingText.get(threadID) ?? [];
    const last = chunks[chunks.length - 1];
    if (last && last.role === role) last.text += text; else chunks.push({ role, text });
    this.pendingText.set(threadID, chunks);
    this.pendingTextBytes += bytes;
    if (this.pendingTextBytes >= STREAM_BYTES) { this.flushStreamText(); return; }
    if (!this.streamTimer) this.streamTimer = setTimeout(() => { this.streamTimer = undefined; this.flushStreamText(); }, this.streamDelay);
  }

  flushStreamText(): void {
    if (this.streamTimer) { clearTimeout(this.streamTimer); this.streamTimer = undefined; }
    if (this.pendingText.size === 0) return;
    const pending = this.pendingText;
    this.pendingText = new Map();
    this.pendingTextBytes = 0;
    this.state.update((d) => {
      for (const project of d.archive.projects) for (const thread of project.threads) {
        const chunks = pending.get(thread.id);
        if (!chunks) continue;
        for (const chunk of chunks) {
          const last = thread.messages[thread.messages.length - 1];
          if (last && last.role === chunk.role && !last.toolActivity) last.text += chunk.text;
          else thread.messages.push(makeMessage(chunk.role, chunk.text) as Draft<ChatMessage>);
        }
      }
    });
    this.saveSoon();
  }

  handle(event: AgentEvent, threadID: string): void {
    if (!this.findThread(threadID)) return;
    const live = () => this.isRunning(threadID) && !this.isStopping(threadID);
    switch (event.type) {
      case "conversationUsage":
        this.mutate(threadID, (t) => {
          // Provider totals are authoritative replacements, including decreases after reset.
          if (!usageDiffersInCounts(event.usage, t.conversationUsage)) return;
          t.conversationUsage = event.usage;
        });
        break;
      case "compaction":
        if (!live()) return;
        this.mutate(threadID, (t) => {
          const previous = t.lastCompaction;
          if (previous && previous.id === event.compaction.id && (previous.state === event.compaction.state || previous.state !== "compacting")) return;
          t.lastCompaction = event.compaction;
        });
        break;
      case "session": this.mutate(threadID, (t) => { t.remoteSessionID = event.id; }); break;
      case "textDelta":
        this.mutate(threadID, (t) => {
          const last = t.messages[t.messages.length - 1];
          if (last?.role === "assistant") last.text += event.text; else t.messages.push(makeMessage("assistant", event.text) as Draft<ChatMessage>);
        });
        break;
      case "activityDelta":
        this.mutate(threadID, (t) => {
          const last = t.messages[t.messages.length - 1];
          if (last?.role === "activity" && !last.toolActivity) last.text += event.text; else t.messages.push(makeMessage("activity", event.text) as Draft<ChatMessage>);
        });
        break;
      case "reasoningDelta":
        this.mutate(threadID, (t) => {
          const last = t.messages[t.messages.length - 1];
          if (last?.role === "reasoning") last.text += event.text; else t.messages.push(makeMessage("reasoning", event.text) as Draft<ChatMessage>);
        });
        break;
      case "message": this.mutate(threadID, (t) => { t.messages.push(makeMessage("assistant", event.text) as Draft<ChatMessage>); }); break;
      case "toolActivity":
        if (!live()) return;
        this.mutate(threadID, (t) => {
          const existing = t.messages.find((m) => m.toolActivity?.id === event.tool.id);
          if (existing) {
            if (existing.toolActivity?.state !== "running") return;
            existing.toolActivity = event.tool; existing.text = toolActivityText(event.tool);
          } else {
            t.messages.push(makeMessage("activity", toolActivityText(event.tool), { toolActivity: event.tool }) as Draft<ChatMessage>);
          }
        });
        break;
      case "interaction":
        if (!live()) return;
        this.state.update((d) => {
          const list = (d.interactions[threadID] ??= []);
          if (!list.some((i) => i.id === event.interaction.id)) list.push(event.interaction as never);
        });
        break;
      case "interactionResolved":
        this.state.update((d) => { if (d.interactions[threadID]) d.interactions[threadID] = d.interactions[threadID].filter((i) => i.id !== event.id); });
        break;
      case "interactionUnavailable": this.mutate(threadID, (t) => { t.messages.push(makeMessage("error", event.text) as Draft<ChatMessage>); }); break;
      case "activity": this.mutate(threadID, (t) => { t.messages.push(makeMessage("activity", event.text) as Draft<ChatMessage>); }); break;
      case "usage": {
        const owner = this.findThread(threadID)!;
        const key = this.usageKey(owner);
        this.state.update((d) => { d.usageSnapshots[key] = mergeUsage(event.usage, d.usageSnapshots[key] as never) as never; });
        break;
      }
      case "failed":
        this.state.update((d) => { toggleIn(d.pausedQueues, threadID, true); });
        this.finishWork(threadID, "failed");
        this.endTurn(threadID);
        this.mutate(threadID, (t) => { t.messages.push(makeMessage("error", event.text) as Draft<ChatMessage>); });
        break;
      case "interrupted":
        this.state.update((d) => { toggleIn(d.pausedQueues, threadID, true); });
        this.finishWork(threadID, "interrupted");
        this.endTurn(threadID);
        break;
      case "finished":
        if (!this.isRunning(threadID)) return;
        this.finishWork(threadID, "completed");
        this.endTurn(threadID);
        this.saveSoon();
        // Yield past the provider callback before beginning another turn.
        setImmediate(() => this.sendNextQueued(threadID));
        break;
      case "approval":
        this.approvalResponders.set(event.approval.id, event.approval.respond);
        this.state.update((d) => {
          const list = (d.approvals[threadID] ??= []);
          if (!list.some((a) => a.id === event.approval.id)) list.push({ id: event.approval.id, title: event.approval.title, detail: event.approval.detail });
        });
        break;
      case "approvalResolved":
        this.approvalResponders.delete(event.id);
        this.state.update((d) => { if (d.approvals[threadID]) d.approvals[threadID] = d.approvals[threadID].filter((a) => a.id !== event.id); });
        break;
    }
  }

  private endTurn(threadID: string): void {
    const approvals = this.s.approvals[threadID] ?? [];
    for (const approval of approvals) this.approvalResponders.delete(approval.id);
    this.state.update((d) => { toggleIn(d.running, threadID, false); d.approvals[threadID] = []; d.interactions[threadID] = []; });
  }

  answer(approvalID: string, threadID: string, allow: boolean): void {
    if (!this.isRunning(threadID) || this.isStopping(threadID) || !this.s.approvals[threadID]?.some((a) => a.id === approvalID)) return;
    this.approvalResponders.get(approvalID)?.(allow);
    this.approvalResponders.delete(approvalID);
    this.state.update((d) => { d.approvals[threadID] = (d.approvals[threadID] ?? []).filter((a) => a.id !== approvalID); });
  }

  /** Returns an error message, or undefined when the response was accepted. */
  respond(interactionID: string, threadID: string, response: AgentInteractionResponse): string | undefined {
    const harness = this.harnesses.get(threadID);
    if (!this.isRunning(threadID) || this.isStopping(threadID) || !this.s.interactions[threadID]?.some((i) => i.id === interactionID) || !harness) {
      return "This request is no longer active.";
    }
    try {
      harness.respond(interactionID, response);
      this.state.update((d) => { d.interactions[threadID] = (d.interactions[threadID] ?? []).filter((i) => i.id !== interactionID); });
      return undefined;
    } catch (error) {
      return (error as Error).message;
    }
  }

  private mutate(id: string, update: (thread: Draft<WorkspaceThread>) => void): void {
    let found = false;
    this.state.update((d) => {
      for (const project of d.archive.projects) {
        const thread = project.threads.find((t) => t.id === id);
        if (thread) { update(thread); found = true; return; }
      }
    });
    if (found) this.saveSoon();
  }

  async shutdown(): Promise<void> {
    this.shuttingDown = true;
    for (const id of [...this.titleAborts.keys()]) this.cancelTitle(id);
    this.flushStreamText();
    for (const id of [...this.turnClocks.keys()]) this.finishWork(id, "interrupted");
    for (const harness of this.harnesses.values()) harness.shutdown();
    await this.saveNow();
    await this.preferences.flush();
    this.state.update((d) => { d.interactions = {}; d.approvals = {}; });
  }
}

