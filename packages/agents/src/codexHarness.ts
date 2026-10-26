import { newID, type AgentPermissionMode, type AgentSettings, type ContextCompaction, type ImageAttachment, type ToolActivity } from "@octo/core";
import { ProcessFailure } from "@octo/core/node";
import { CodexExecutable, versionAtLeast } from "./codexExecutable";
import { decodeCodexCommands, codexCommandInput, commandMentions } from "./commands";
import { decodeCodexConversationUsage, decodeCodexModel, decodeCodexUsage } from "./codexDecoding";
import { CodexInteraction } from "./codexInteractions";
import type { AgentInteractionResponse } from "./interaction";
import { requestKey, RPCConnection, type JSONObject } from "./jsonLine";
import { AgentToolDetails } from "./toolDetails";
import type { AgentCommand, AgentEvent, AgentHarness, AgentModel, AgentPermissionOption, AgentUsage } from "./types";

const CLIENT_INFO = { name: "octo", title: "Octo", version: "0.1.0" };
const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

interface PendingInteraction {
  wireID: unknown;
  key: string;
  connection: string;
  epoch: string;
  decoded: CodexInteraction;
}

/**
 * One long-lived `codex app-server` per thread. Pending requests get fresh local IDs bound to the
 * connection, turn epoch and typed wire request ID; resolution, interruption, disconnect,
 * completion and shutdown invalidate them.
 */
export class CodexHarness implements AgentHarness {
  onEvent?: (event: AgentEvent) => void;
  private readonly rpc = new RPCConnection();
  private threadID: string | undefined;
  private turnID: string | undefined;
  // Retain the completed turn's identity for usage delivered just after turn/completed.
  private usageTurnID: string | undefined;
  private compactions = new Map<string, ContextCompaction>();
  private busy = false;
  private initialized = false;
  private streamedItems = new Set<string>();
  private reasoningItems = new Set<string>();
  private commentaryItems = new Set<string>();
  private autoReviewVerified = false;
  private extendedInteractions = false;
  private connectionID = newID();
  private turnEpoch = newID();
  private acceptingRequests = false;
  private computerUseActive = false;
  private supportsComputerUseCleanup = false;
  private cleanupTask: Promise<void> | undefined;
  private closed = false;
  private directory: string | undefined;
  private interactions = new Map<string, PendingInteraction>();
  private approvalKeys = new Map<string, { id: string; epoch: string }>();
  private seenRequests = new Set<string>();
  private tools = new Map<string, ToolActivity>();
  private readonly executableOverride: string | undefined;

  constructor(executable?: string) {
    this.executableOverride = executable;
    this.rpc.onNotification = (method, params) => this.notification(method, params);
    this.rpc.onRequest = (id, method, params) => this.serverRequest(id, method, params);
    this.rpc.onDisconnect = (detail) => {
      this.initialized = false;
      this.invalidateRequests(); this.endTools(); this.acceptingRequests = false;
      if (this.busy) { this.busy = false; this.emit({ type: "failed", text: AgentToolDetails.text(detail) }); }
    };
  }

  private emit(event: AgentEvent): void {
    this.onEvent?.(event);
  }

  static readonly permissionOptions: AgentPermissionOption[] = [
    { mode: "readOnly", title: "Read only", detail: "Read files. File writes and network access stay blocked; no escalation requests." },
    { mode: "ask", title: "Ask for approval", detail: "Edit this workspace. Ask before leaving the sandbox or accessing the network." },
    { mode: "autoReview", title: "Approve for me", detail: "Edit this workspace. Codex reviews requests to leave the sandbox. Requires CLI 0.158.0 or newer." },
    { mode: "fullAccess", title: "Full access", detail: "Unrestricted file and network access, without approval prompts." },
  ];

  static supportsAutoReview(version: string): boolean { return versionAtLeast(version, 158); }
  /** Conservative implementation baseline, separately declared from permission support. */
  static supportsInteractionExtensions(version: string): boolean { return CodexHarness.supportsAutoReview(version); }
  static supportsComputerUseCleanup(version: string): boolean { return versionAtLeast(version, 160); }

  private static approvalPolicy(mode: AgentPermissionMode): string {
    return mode === "readOnly" || mode === "fullAccess" ? "never" : "on-request";
  }
  private static sandboxMode(mode: AgentPermissionMode): string {
    return mode === "readOnly" ? "read-only" : mode === "fullAccess" ? "danger-full-access" : "workspace-write";
  }
  private static sandboxPolicy(mode: AgentPermissionMode, directory: string): JSONObject {
    if (mode === "readOnly") return { type: "readOnly", networkAccess: false };
    if (mode === "fullAccess") return { type: "dangerFullAccess" };
    return { type: "workspaceWrite", writableRoots: [directory], networkAccess: false };
  }

  private requireActive(epoch: string): void {
    if (!this.busy || !this.acceptingRequests || this.turnEpoch !== epoch) throw new ProcessFailure("exited", "Turn startup was cancelled.");
  }

  async send(prompt: string, sessionID: string | undefined, directory: string, settings: AgentSettings = {}, images: ImageAttachment[] = []): Promise<void> {
    if (this.cleanupTask) await this.cleanupTask;
    if (this.closed) throw new ProcessFailure("exited", "This agent connection has closed.");
    if (this.busy) throw new ProcessFailure("exited", "This thread already has a running turn.");
    const executable = this.executableOverride ?? CodexExecutable.resolve();
    if (!executable) throw new ProcessFailure("missing", "codex");
    this.busy = true; this.acceptingRequests = true; this.turnID = undefined; this.turnEpoch = newID();
    this.usageTurnID = undefined; this.compactions.clear();
    this.computerUseActive = false;
    const epoch = this.turnEpoch;
    try {
      const mode = settings.permissionMode ?? "ask";
      if (mode === "autoReview" && !this.autoReviewVerified) {
        const version = await CodexExecutable.version(executable);
        this.requireActive(epoch);
        if (!CodexHarness.supportsAutoReview(version)) {
          throw new ProcessFailure("exited", "Approve for me requires Codex CLI 0.158.0 or newer. Choose Ask for approval or select a supported CLI in Settings.");
        }
        this.autoReviewVerified = true;
      }
      if (!this.rpc.running) {
        this.connectionID = newID(); this.seenRequests.clear(); this.tools.clear();
        const version = await CodexExecutable.version(executable).catch(() => "");
        this.requireActive(epoch);
        this.extendedInteractions = CodexHarness.supportsInteractionExtensions(version);
        this.supportsComputerUseCleanup = CodexHarness.supportsComputerUseCleanup(version);
        this.rpc.start(executable, directory);
        const initialize: JSONObject = { clientInfo: CLIENT_INFO };
        if (this.extendedInteractions) initialize.capabilities = { experimentalApi: true, mcpServerOpenaiFormElicitation: true };
        await this.rpc.request("initialize", initialize);
        this.requireActive(epoch);
        this.rpc.notify("initialized"); this.initialized = true; this.threadID = undefined;
      }
      if (!this.initialized) throw new ProcessFailure("exited", "Codex connection is not initialized.");
      this.directory = directory;
      if (this.threadID === undefined) {
        const params: JSONObject = {
          cwd: directory, approvalPolicy: CodexHarness.approvalPolicy(mode),
          approvalsReviewer: mode === "autoReview" ? "auto_review" : "user", sandbox: CodexHarness.sandboxMode(mode),
        };
        if (sessionID !== undefined) params.threadId = sessionID;
        if (settings.model !== undefined) params.model = settings.model;
        const result = await this.rpc.request(sessionID === undefined ? "thread/start" : "thread/resume", params);
        this.requireActive(epoch);
        const id = isObject(result.thread) ? str(result.thread.id) : undefined;
        if (!id) throw new ProcessFailure("exited", "Codex returned no thread ID.");
        this.threadID = id;
        this.emit({ type: "session", id });
      }
      const threadID = this.threadID;
      if (!threadID) return;
      this.tools.clear(); this.streamedItems.clear(); this.reasoningItems.clear(); this.commentaryItems.clear();
      const input = await this.commandInput(prompt, directory);
      this.requireActive(epoch);
      for (const image of images) input.push({ type: "image", url: "data:image/png;base64," + image.pngBase64 });
      const params: JSONObject = {
        threadId: threadID, input, cwd: directory, approvalPolicy: CodexHarness.approvalPolicy(mode),
        approvalsReviewer: mode === "autoReview" ? "auto_review" : "user", sandboxPolicy: CodexHarness.sandboxPolicy(mode, directory),
      };
      if (settings.model !== undefined) params.model = settings.model;
      if (settings.reasoningEffort !== undefined) params.effort = settings.reasoningEffort;
      const result = await this.rpc.request("turn/start", params);
      if (this.busy && this.turnEpoch === epoch) {
        this.turnID = isObject(result.turn) ? str(result.turn.id) : undefined;
        this.usageTurnID = this.turnID;
      }
    } catch (error) {
      if (this.turnEpoch === epoch) { this.busy = false; this.acceptingRequests = false; this.invalidateRequests(); this.endTools(); }
      throw error;
    }
  }

  async steer(prompt: string, images: ImageAttachment[] = []): Promise<void> {
    const threadID = this.threadID, turnID = this.turnID;
    if (!this.busy || !this.acceptingRequests || this.closed || !threadID || !turnID) {
      throw new ProcessFailure("exited", "The turn is starting or has already ended. Your message remains queued.");
    }
    const epoch = this.turnEpoch;
    const input = await this.commandInput(prompt, this.directory ?? "");
    if (!this.busy || !this.acceptingRequests || this.turnID !== turnID || this.turnEpoch !== epoch) {
      throw new ProcessFailure("exited", "The turn ended during skill discovery. Your message remains queued.");
    }
    for (const image of images) input.push({ type: "image", url: "data:image/png;base64," + image.pngBase64 });
    const result = await this.rpc.request("turn/steer", { threadId: threadID, expectedTurnId: turnID, input });
    if (result.turnId !== turnID) {
      throw new ProcessFailure("exited", "The CLI did not confirm the expected turn. Check the conversation before retrying this message.");
    }
  }

  private async commandInput(prompt: string, directory: string): Promise<JSONObject[]> {
    const mentions = commandMentions(prompt);
    const first = mentions[0];
    if (!first) return prompt ? [{ type: "text", text: prompt }] : [];
    try {
      const commands = decodeCodexCommands(await this.rpc.request("skills/list", { cwds: [directory], forceReload: true }), directory);
      return codexCommandInput(prompt, commands);
    } catch (error) {
      // A "/word" mid-message may be a path; only a leading command must resolve.
      if (first.index !== 0) return [{ type: "text", text: prompt }];
      throw error;
    }
  }

  // MARK: Read-only discovery on separate connections

  private static async withConnection<T>(directory: string, executable: string | undefined, body: (connection: RPCConnection) => Promise<T>): Promise<T> {
    const resolved = executable ?? CodexExecutable.resolve();
    if (!resolved) throw new ProcessFailure("missing", "codex");
    const connection = new RPCConnection();
    try {
      connection.start(resolved, directory);
      await connection.request("initialize", { clientInfo: CLIENT_INFO });
      connection.notify("initialized");
      return await body(connection);
    } finally {
      connection.close();
    }
  }

  /** Read-only account endpoint; never starts a thread or turn. */
  static usage(directory: string, executable?: string): Promise<AgentUsage> {
    return CodexHarness.withConnection(directory, executable, async (c) => decodeCodexUsage(await c.request("account/rateLimits/read", {})));
  }

  /** Read-only discovery (app-server v2 `model/list`, including pagination). */
  static models(directory: string, executable?: string, signal?: AbortSignal): Promise<AgentModel[]> {
    return CodexHarness.withConnection(directory, executable, async (connection) => {
      const models: AgentModel[] = [];
      const seen = new Set<string>();
      let cursor: string | undefined;
      do {
        if (signal?.aborted) throw new ProcessFailure("exited", "Model discovery was cancelled.");
        const params: JSONObject = { limit: 100, includeHidden: false };
        if (cursor !== undefined) params.cursor = cursor;
        const page = await connection.request("model/list", params);
        if (!Array.isArray(page.data)) throw new ProcessFailure("exited", "Codex returned a malformed model list.");
        for (const raw of page.data) {
          const model = decodeCodexModel(raw);
          if (!model.hidden && !models.some((m) => m.model === model.model)) models.push(model);
        }
        cursor = typeof page.nextCursor === "string" ? page.nextCursor : undefined;
        if (cursor !== undefined) {
          if (seen.has(cursor)) throw new ProcessFailure("exited", "Codex returned a repeated model-list cursor.");
          seen.add(cursor);
        }
      } while (cursor !== undefined);
      return models;
    });
  }

  static commands(directory: string, executable?: string): Promise<AgentCommand[]> {
    return CodexHarness.withConnection(directory, executable, async (c) =>
      decodeCodexCommands(await c.request("skills/list", { cwds: [directory], forceReload: true }), directory));
  }

  // MARK: Notifications and requests

  private notification(method: string, p: JSONObject): void {
    if (this.closed) return;
    if (method === "thread/tokenUsage/updated") {
      if (!this.threadID || !this.usageTurnID || p.threadId !== this.threadID || p.turnId !== this.usageTurnID) return;
      let usage;
      try { usage = decodeCodexConversationUsage(p); } catch { return; }
      this.emit({ type: "conversationUsage", usage });
      return;
    }
    if (typeof p.threadId === "string" && this.threadID !== undefined && p.threadId !== this.threadID) return;
    if (typeof p.turnId === "string" && this.turnID !== undefined && p.turnId !== this.turnID) return;
    if (method === "turn/completed") {
      const id = isObject(p.turn) ? str(p.turn.id) : undefined;
      if (id !== undefined && this.turnID !== undefined && id !== this.turnID) return;
    }
    if (!this.busy && method !== "account/rateLimits/updated" && method !== "serverRequest/resolved") return;
    switch (method) {
      case "item/mcpToolCall/progress": {
        const id = str(p.itemId);
        const tool = id !== undefined ? this.tools.get(id) : undefined;
        if (p.threadId !== this.threadID || p.turnId !== this.turnID || !id || !tool || tool.state !== "running") return;
        const updated = { ...tool, detail: AgentToolDetails.text(str(p.message) ?? "") };
        if (updated.detail !== tool.detail) { this.tools.set(id, updated); this.emit({ type: "toolActivity", tool: updated }); }
        break;
      }
      case "turn/started": {
        const id = isObject(p.turn) ? str(p.turn.id) : undefined;
        if (id !== undefined && (this.turnID === undefined || this.turnID === id)) { this.turnID = id; this.usageTurnID = id; }
        break;
      }
      case "item/agentMessage/delta": {
        const itemID = str(p.itemId);
        if (itemID !== undefined) this.streamedItems.add(itemID);
        const delta = str(p.delta);
        if (delta !== undefined) this.emit(this.commentaryItems.has(itemID ?? "") ? { type: "activityDelta", text: delta } : { type: "textDelta", text: delta });
        break;
      }
      case "item/reasoning/summaryTextDelta": {
        const itemID = str(p.itemId);
        if (itemID !== undefined) this.reasoningItems.add(itemID);
        const delta = str(p.delta);
        if (delta !== undefined) this.emit({ type: "reasoningDelta", text: delta });
        break;
      }
      case "item/reasoning/summaryPartAdded": {
        const itemID = str(p.itemId);
        if (itemID !== undefined && this.reasoningItems.has(itemID)) this.emit({ type: "reasoningDelta", text: "\n\n" });
        break;
      }
      case "account/rateLimits/updated": {
        try { this.emit({ type: "usage", usage: decodeCodexUsage(p) }); } catch { /* ignore malformed */ }
        break;
      }
      case "item/started": case "item/completed":
        this.item(method, p);
        break;
      case "turn/completed": {
        this.invalidateRequests(); this.endTools(); this.acceptingRequests = false;
        const completedTurnID = this.turnID;
        this.busy = false; this.turnID = undefined;
        const turn = isObject(p.turn) ? p.turn : {};
        let event: AgentEvent;
        if (turn.status === "failed") {
          const error = isObject(turn.error) ? turn.error : undefined;
          event = { type: "failed", text: str(error?.message) ?? "Codex turn failed." };
        } else if (turn.status === "interrupted") event = { type: "interrupted" };
        else event = { type: "finished" };
        this.completeTurn(event, completedTurnID, turn.status !== "completed");
        break;
      }
      case "serverRequest/resolved": {
        const key = requestKey(p.requestId);
        if (!key) return;
        for (const [id, pending] of [...this.interactions]) {
          if (pending.key === key) { this.interactions.delete(id); this.emit({ type: "interactionResolved", id }); }
        }
        const approval = this.approvalKeys.get(key);
        if (approval) { this.approvalKeys.delete(key); this.emit({ type: "approvalResolved", id: approval.id }); }
        break;
      }
      case "error": {
        if (p.willRetry !== true) {
          const error = isObject(p.error) ? p.error : undefined;
          this.emit({ type: "activity", text: str(error?.message) ?? "Codex reported an error." });
        }
        break;
      }
    }
  }

  private item(method: string, p: JSONObject): void {
    const item = isObject(p.item) ? p.item : undefined;
    const type = str(item?.type);
    if (!item || !type) return;
    if (type === "contextCompaction") {
      const id = str(item.id);
      if (!this.acceptingRequests || !this.threadID || !this.turnID || p.threadId !== this.threadID || p.turnId !== this.turnID || !id) return;
      const state = method === "item/started" ? "compacting" : "completed";
      const previous = this.compactions.get(id);
      if (previous && (previous.state === state || previous.state !== "compacting")) return;
      const compaction: ContextCompaction = previous
        ? { ...previous, state }
        : { id: `${this.connectionID}:${this.turnEpoch}:${id}`, state, startedAt: Date.now() };
      if (state === "completed") compaction.endedAt = Date.now();
      this.compactions.set(id, compaction);
      this.emit({ type: "compaction", compaction });
      return;
    }
    if (type === "mcpToolCall") {
      const id = str(item.id), server = str(item.server), name = str(item.tool);
      if (p.threadId !== this.threadID || p.turnId !== this.turnID || !id || server === undefined || name === undefined) return;
      const previous = this.tools.get(id);
      if (previous && previous.state !== "running") return;
      if (server === "cua_repl") {
        if (name === "turn_ended") {
          if (method === "item/completed" && item.status === "completed") this.computerUseActive = false;
        } else this.computerUseActive = true;
      }
      const state = item.status === "failed" ? "failed" : method === "item/completed" ? "completed" : "running";
      const tool: ToolActivity = {
        id: `${this.connectionID}:${this.turnEpoch}:${id}`, server: AgentToolDetails.text(server, 256), tool: AgentToolDetails.text(name, 256),
        state, detail: AgentToolDetails.result(item),
      };
      if (!previous || previous.state !== tool.state || previous.detail !== tool.detail || previous.server !== tool.server || previous.tool !== tool.tool) {
        this.tools.set(id, tool);
        this.emit({ type: "toolActivity", tool });
      }
    }
    const itemID = str(item.id) ?? "";
    if (type === "agentMessage" && item.phase === "commentary" && method === "item/started") {
      if (str(item.id) !== undefined) this.commentaryItems.add(itemID);
      this.emit({ type: "activity", text: "" });
    }
    if (type === "agentMessage" && method === "item/completed" && typeof item.text === "string" && !this.streamedItems.has(itemID)) {
      if (item.phase === "commentary") {
        this.emit(this.commentaryItems.has(itemID) ? { type: "activityDelta", text: item.text } : { type: "activity", text: item.text });
      } else this.emit({ type: "message", text: item.text });
    }
    if (type === "reasoning" && method === "item/completed" && !this.reasoningItems.has(itemID) &&
        Array.isArray(item.summary) && item.summary.length > 0 && item.summary.every((s) => typeof s === "string")) {
      this.emit({ type: "reasoningDelta", text: (item.summary as string[]).join("\n\n") });
    }
    if (method === "item/started" && type === "commandExecution") this.emit({ type: "activity", text: str(item.command) ?? "Running command" });
    if (method === "item/completed" && type === "fileChange") this.emit({ type: "activity", text: "Updated files" });
  }

  private serverRequest(id: unknown, method: string, p: JSONObject): void {
    const key = requestKey(id);
    if (!key || this.seenRequests.has(key)) return;
    this.seenRequests.add(key);
    const elicitation = method === "mcpServer/elicitation/request";
    const questions = method === "item/tool/requestUserInput";
    if (!this.busy || !this.acceptingRequests ||
        !(p.threadId === undefined || p.threadId === null || p.threadId === this.threadID) ||
        !(p.turnId === undefined || p.turnId === null || p.turnId === this.turnID)) {
      if (elicitation) this.rpc.respond(id, { action: "cancel", content: null });
      else if (questions) this.rpc.respond(id, { answers: {} });
      else this.rpc.reject(id, method);
      return;
    }
    if (elicitation || questions) {
      try {
        const owner = this.threadID;
        if (!owner || p.threadId !== owner ||
            !(questions || (typeof p.serverName === "string" && p.serverName !== "")) ||
            !(!questions || (typeof p.itemId === "string" && p.itemId !== "" && typeof p.isBlocking === "boolean")) ||
            !(!questions || (this.extendedInteractions && p.turnId === this.turnID)) ||
            !(p.mode === "form" || questions || this.extendedInteractions)) {
          throw new ProcessFailure("exited", "Unsupported interaction context or experimental API; use a supported Codex CLI (0.158 or newer).");
        }
        const decoded = CodexInteraction.decode(p, questions);
        this.interactions.set(decoded.request.id, { wireID: id, key, connection: this.connectionID, epoch: this.turnEpoch, decoded });
        this.emit({ type: "interaction", interaction: decoded.request });
      } catch (error) {
        this.rpc.respond(id, questions ? { answers: {} } : { action: "decline", content: null });
        this.emit({ type: "interactionUnavailable", text: (error as Error).message });
      }
    } else if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
      const detail = [p.command, p.cwd, p.reason, p.grantRoot].filter((v): v is string => typeof v === "string").join("\n");
      const localID = newID(), epoch = this.turnEpoch, connection = this.connectionID;
      this.approvalKeys.set(key, { id: localID, epoch });
      this.emit({
        type: "approval",
        approval: {
          id: localID,
          title: method.includes("commandExecution") ? "Command approval" : "File change approval",
          detail: detail || "The agent requests permission for this operation.",
          respond: (allow) => {
            if (this.connectionID !== connection || this.turnEpoch !== epoch || this.approvalKeys.get(key)?.id !== localID || !this.acceptingRequests) return;
            this.approvalKeys.delete(key);
            this.rpc.respond(id, { decision: allow ? "accept" : "decline" });
            this.emit({ type: "approvalResolved", id: localID });
          },
        },
      });
    } else if (method === "item/permissions/requestApproval") {
      this.rpc.respond(id, { permissions: {}, scope: "turn" });
      this.emit({ type: "interactionUnavailable", text: "Additional permission request declined: this request type is not yet supported." });
    } else {
      this.rpc.reject(id, method);
      this.emit({ type: "interactionUnavailable", text: `Unsupported agent request: ${method}` });
    }
  }

  respond(id: string, response: AgentInteractionResponse): void {
    const pending = this.interactions.get(id);
    if (!pending || pending.connection !== this.connectionID || pending.epoch !== this.turnEpoch || !this.busy || !this.acceptingRequests || !this.rpc.running) {
      throw new ProcessFailure("exited", "This request is no longer active.");
    }
    const result = pending.decoded.response(response);
    this.rpc.sendResponse(pending.wireID, result);
    this.interactions.delete(id);
    this.emit({ type: "interactionResolved", id });
  }

  private invalidateRequests(cancel = false): void {
    const pending = [...this.interactions];
    this.interactions.clear();
    for (const [id, request] of pending) {
      if (cancel) { try { this.rpc.respond(request.wireID, request.decoded.response({ type: "cancel" })); } catch { /* gone */ } }
      this.emit({ type: "interactionResolved", id });
    }
    for (const approval of this.approvalKeys.values()) this.emit({ type: "approvalResolved", id: approval.id });
    this.approvalKeys.clear();
  }

  private endTools(): void {
    for (const [id, tool] of this.tools) {
      if (tool.state !== "running") continue;
      const ended = { ...tool, state: "interrupted" as const };
      this.tools.set(id, ended);
      this.emit({ type: "toolActivity", tool: ended });
    }
  }

  /** The bundled unified-computer-use plugin's Stop/Interrupt hook, inside the CLI's existing connection. */
  private cleanupParameters(turn: string | undefined, interrupted: boolean): JSONObject | undefined {
    if (!this.computerUseActive || !this.threadID || !turn) return undefined;
    this.computerUseActive = false;
    return {
      threadId: this.threadID, server: "cua_repl", tool: "turn_ended",
      arguments: { hook_event_name: interrupted ? "Interrupt" : "Stop", session_id: this.threadID, turn_id: turn },
    };
  }

  private completeTurn(event: AgentEvent, turn: string | undefined, interrupted: boolean): void {
    const params = this.cleanupParameters(turn, interrupted);
    if (!params) { this.emit(event); return; }
    const epoch = this.turnEpoch;
    this.cleanupTask = (async () => {
      try {
        if (!this.supportsComputerUseCleanup) throw new ProcessFailure("exited", "Requires Codex CLI 0.160 or newer.");
        const result = await this.rpc.request("mcpServer/tool/call", params, 5_000);
        if (result.isError === true) throw new ProcessFailure("exited", "The computer-use runtime rejected cleanup.");
      } catch (error) {
        if (!this.closed) this.emit({ type: "interactionUnavailable", text: `Computer Use cleanup could not be confirmed: ${(error as Error).message}` });
      }
      if (this.closed || this.turnEpoch !== epoch) return;
      this.cleanupTask = undefined;
      this.emit(event);
    })();
  }

  async interrupt(): Promise<void> {
    this.acceptingRequests = false; this.invalidateRequests(true); this.endTools();
    const threadID = this.threadID, turnID = this.turnID;
    if (!threadID || !turnID) {
      if (this.busy) { this.rpc.close(); this.busy = false; this.initialized = false; this.emit({ type: "finished" }); }
      return;
    }
    await this.rpc.request("turn/interrupt", { threadId: threadID, turnId: turnID }).catch(() => undefined);
  }

  shutdown(): void {
    if (this.closed) return;
    this.closed = true; this.acceptingRequests = false; this.usageTurnID = undefined;
    this.invalidateRequests(true); this.endTools();
    const params = this.cleanupParameters(this.turnID, true);
    const pending = this.cleanupTask, rpc = this.rpc, activeThread = this.threadID, activeTurn = this.turnID, wasBusy = this.busy;
    this.busy = false;
    if (pending || (params && this.supportsComputerUseCleanup)) {
      void (async () => {
        if (pending) await pending;
        if (wasBusy && activeThread && activeTurn) {
          await rpc.request("turn/interrupt", { threadId: activeThread, turnId: activeTurn }, 2_000).catch(() => undefined);
        }
        if (params) await rpc.request("mcpServer/tool/call", params, 2_000).catch(() => undefined);
        rpc.close();
      })();
    } else rpc.close();
  }
}
