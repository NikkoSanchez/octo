import { newID, type AgentSettings, type ContextCompaction, type ImageAttachment, type ToolActivity } from "@octo/core";
import { CancellationError, findExecutable, ProcessFailure } from "@octo/core/node";
import { ClaudeConnection } from "./claudeConnection";
import { decodeClaudeContextUsage, decodeClaudeRateLimit } from "./claudeUsage";
import { decodeClaudeCommands } from "./commands";
import { interactionValidationError, makeField, makeInteraction, type AgentInteraction, type AgentInteractionResponse, type InteractionField } from "./interaction";
import type { JSONObject } from "./jsonLine";
import { AgentToolDetails } from "./toolDetails";
import type { AgentCommand, AgentEvent, AgentHarness, AgentModel, AgentPermissionOption } from "./types";
import { ClaudeTranscriptUsage } from "./usageLedger";

const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

interface Question {
  requestID: string;
  input: JSONObject;
  interaction: AgentInteraction;
}

/**
 * Uses the user's CLI, auth and settings. Each turn initializes a fresh `claude -p` connection and
 * resumes explicitly, so settings changes cannot inherit a broader permission mode.
 */
export class ClaudeHarness implements AgentHarness {
  onEvent?: (event: AgentEvent) => void;
  private readonly executableOverride: string | undefined;
  private connection: ClaudeConnection | undefined;
  private generation = newID();
  private active = false;
  private ready = false;
  private confirmedPermissionMode: string | undefined;
  private remoteSession: string | undefined;
  private streamedBlocks = new Set<number>();
  private thinkingBlocks = new Set<number>();
  private completedMessages = new Set<string>();
  private seenRequests = new Set<string>();
  private tools = new Map<string, ToolActivity>();
  private approvals = new Map<string, { localID: string; input: JSONObject }>();
  private questions = new Map<string, Question>();
  private readonly projectsDirectory: string;
  private compaction: ContextCompaction | undefined;
  private contextQueryActive = false;
  private contextQueryPending = false;
  /** Only the most recently started context query may report, so a slow reply cannot replace a newer one. */
  private contextEpoch = 0;
  /** A finished turn's connection, kept open only for its final context query. */
  private draining: ClaudeConnection | undefined;
  private startup: AbortController | undefined;

  constructor(executable?: string, projectsDirectory = ClaudeTranscriptUsage.projectsDirectory()) {
    this.executableOverride = executable;
    this.projectsDirectory = projectsDirectory;
  }

  private emit(event: AgentEvent): void {
    this.onEvent?.(event);
  }

  static readonly permissionOptions: AgentPermissionOption[] = [
    { mode: "ask", title: "Manual", detail: "Claude follows its permission rules and asks before operations that require approval." },
    { mode: "autoReview", title: "Auto", detail: "Claude reviews actions automatically and asks when its permission rules require you. Availability depends on the CLI, model and managed policies." },
  ];

  static arguments(settings: AgentSettings, sessionID: string | undefined): string[] {
    const mode = ClaudeHarness.permissionMode(settings);
    if (settings.reasoningEffort !== undefined && !EFFORTS.includes(settings.reasoningEffort)) throw new ProcessFailure("exited", "Unsupported Claude effort level.");
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode];
    if (settings.model !== undefined) args.push("--model", settings.model);
    if (settings.reasoningEffort !== undefined) args.push("--effort", settings.reasoningEffort);
    // Optional-value flags must bind their argument even if a saved value starts with '-'.
    if (sessionID !== undefined) args.push(`--resume=${sessionID}`);
    return args;
  }

  private static permissionMode(settings: AgentSettings): string {
    switch (settings.permissionMode ?? "autoReview") {
      case "ask": return "manual";
      case "autoReview": return "auto";
      default: throw new ProcessFailure("exited", "This Claude adapter supports Manual and Auto. Claude plan mode is not an OS read-only sandbox; full access is not mapped.");
    }
  }

  static validatePermissions(response: JSONObject, settings: AgentSettings): void {
    const requested = ClaudeHarness.permissionMode(settings);
    const actual = str(response.current_permission_mode);
    if (actual === undefined) {
      if (requested === "auto") throw new ProcessFailure("exited", "This Claude CLI did not confirm Auto mode. Update Claude Code or choose Manual before sending.");
      return;
    }
    const expected = requested === "manual" ? "default" : requested;
    if ((actual === "manual" ? "default" : actual) !== expected) {
      throw new ProcessFailure("exited", `Claude did not enable the requested ${requested === "auto" ? "Auto" : "Manual"} mode (reported ${AgentToolDetails.text(actual, 80)}). Check the model and CLI permission settings, or choose Manual before sending.`);
    }
  }

  async send(prompt: string, sessionID: string | undefined, directory: string, settings: AgentSettings = {}, images: ImageAttachment[] = []): Promise<void> {
    if (this.active) throw new ProcessFailure("exited", "This thread already has a running turn.");
    const args = ClaudeHarness.arguments(settings, sessionID);
    const executable = this.executableOverride ?? findExecutable("claude");
    if (!executable) throw new ProcessFailure("missing", "claude");
    const owner = newID(), client = new ClaudeConnection(), startup = new AbortController();
    this.generation = owner; this.active = true; this.ready = false; this.connection = client; this.remoteSession = sessionID;
    this.confirmedPermissionMode = undefined; this.startup = startup;
    this.streamedBlocks.clear(); this.thinkingBlocks.clear(); this.completedMessages.clear(); this.seenRequests.clear(); this.tools.clear();
    this.compaction = undefined; this.contextQueryActive = false; this.contextQueryPending = false;
    client.onObject = (object) => {
      if (this.generation !== owner || !this.active) return;
      this.receive(object);
    };
    client.onDisconnect = (detail) => {
      if (this.generation !== owner || !this.active) return;
      this.end({ type: "failed", text: detail });
    };
    try {
      client.start(executable, directory, args);
      const initialized = await client.request({ subtype: "initialize" }, 30_000, startup.signal);
      if (!this.active || this.generation !== owner || startup.signal.aborted) throw new CancellationError();
      ClaudeHarness.validatePermissions(initialized, settings);
      this.confirmedPermissionMode = str(initialized.current_permission_mode);
      if (settings.model !== undefined) {
        const model = ClaudeHarness.decodeModels(initialized).find((m) => m.model === settings.model);
        if (!model) throw new ProcessFailure("exited", "The selected Claude model is unavailable. Refresh models and choose again.");
        if (settings.reasoningEffort !== undefined && !model.supportedReasoningEfforts.some((e) => e.reasoningEffort === settings.reasoningEffort)) {
          throw new ProcessFailure("exited", "The selected Claude model does not advertise this effort level.");
        }
      }
      const content: JSONObject[] = [];
      if (prompt) content.push({ type: "text", text: prompt });
      for (const image of images) content.push({ type: "image", source: { type: "base64", media_type: "image/png", data: image.pngBase64 } });
      this.ready = true;
      client.transport.write({ type: "user", session_id: sessionID ?? "", parent_tool_use_id: null, message: { role: "user", content } });
    } catch (error) {
      client.close();
      if (this.generation === owner) { this.active = false; this.connection = undefined; this.invalidateRequests(); }
      throw error;
    } finally {
      if (this.startup === startup) this.startup = undefined;
    }
  }

  private static async withDiscovery<T>(directory: string, executable: string | undefined, body: (response: JSONObject) => T): Promise<T> {
    const resolved = executable ?? findExecutable("claude");
    if (!resolved) throw new ProcessFailure("missing", "claude");
    const client = new ClaudeConnection();
    try {
      // Catalog discovery must still work when Auto is unavailable, and submits no prompt.
      client.start(resolved, directory, ClaudeHarness.arguments({ permissionMode: "ask" }, undefined));
      return body(await client.request({ subtype: "initialize" }));
    } finally {
      client.close();
    }
  }

  static models(directory: string, executable?: string): Promise<AgentModel[]> {
    return ClaudeHarness.withDiscovery(directory, executable, (r) => ClaudeHarness.decodeModels(r));
  }

  static commands(directory: string, executable?: string): Promise<AgentCommand[]> {
    return ClaudeHarness.withDiscovery(directory, executable, (r) => decodeClaudeCommands(r));
  }

  static decodeModels(response: JSONObject): AgentModel[] {
    const values = response.models;
    if (!Array.isArray(values) || values.length === 0) throw new ProcessFailure("exited", "This Claude CLI did not report a model catalog. CLI defaults remain available.");
    const seen = new Set<string>();
    const models: AgentModel[] = [];
    for (const value of values) {
      if (!isObject(value) || typeof value.value !== "string" || value.value === "" || seen.has(value.value)) continue;
      seen.add(value.value);
      const efforts = value.supportsEffort === true && Array.isArray(value.supportedEffortLevels)
        ? (value.supportedEffortLevels.filter((e) => typeof e === "string" && EFFORTS.includes(e)) as string[]) : [];
      models.push({
        model: value.value, displayName: str(value.displayName) ?? value.value, description: str(value.description) ?? "",
        hidden: false, isDefault: value.value === "default", defaultReasoningEffort: "", inputModalities: ["text", "image"],
        supportedReasoningEfforts: efforts.map((e) => ({ reasoningEffort: e, description: `Claude CLI effort: ${e}` })),
      });
    }
    return models;
  }

  private receive(object: JSONObject): void {
    const type = str(object.type);
    if (type === "control_request") { this.controlRequest(object); return; }
    if (type === "control_cancel_request" && typeof object.request_id === "string") { this.resolve(object.request_id); return; }
    if (!this.ready) return;
    // Child-agent text must not replace the owning assistant response.
    if (object.parent_tool_use_id !== undefined && object.parent_tool_use_id !== null) return;
    const session = str(object.session_id);
    if (session) {
      if (this.remoteSession !== undefined && session !== this.remoteSession) return;
      if (this.remoteSession === undefined) { this.remoteSession = session; this.emit({ type: "session", id: session }); }
    }
    switch (type) {
      case "stream_event": this.stream(isObject(object.event) ? object.event : {}); break;
      case "assistant": {
        const message = isObject(object.message) ? object.message : undefined;
        if (!message) return;
        if (typeof message.id === "string") {
          if (this.completedMessages.has(message.id)) return;
          this.completedMessages.add(message.id);
        }
        this.refreshContext();
        const blocks = Array.isArray(message.content) ? message.content : [];
        blocks.forEach((block, index) => {
          if (!isObject(block)) return;
          if (block.type === "text") { if (!this.streamedBlocks.has(index) && typeof block.text === "string") this.emit({ type: "message", text: block.text }); }
          else if (block.type === "thinking") { if (!this.thinkingBlocks.has(index) && typeof block.thinking === "string") this.emit({ type: "reasoningDelta", text: block.thinking }); }
          else if (block.type === "tool_use") this.startTool(block);
        });
        this.streamedBlocks.clear(); this.thinkingBlocks.clear();
        break;
      }
      case "user": {
        const message = isObject(object.message) ? object.message : {};
        for (const block of Array.isArray(message.content) ? message.content : []) {
          if (!isObject(block) || block.type !== "tool_result" || typeof block.tool_use_id !== "string") continue;
          const tool = this.tools.get(block.tool_use_id);
          if (!tool || tool.state !== "running") continue;
          const updated: ToolActivity = { ...tool, state: block.is_error === true ? "failed" : "completed" };
          // Tool bodies can contain secrets or binary data. Only display bounded text.
          if (typeof block.content === "string") updated.detail = AgentToolDetails.text(block.content);
          else if (Array.isArray(block.content)) {
            updated.detail = AgentToolDetails.text(block.content.slice(0, 16)
              .map((b) => (isObject(b) && b.type === "text" && typeof b.text === "string" ? b.text : undefined))
              .filter((t): t is string => t !== undefined).join("\n"));
          }
          this.tools.set(block.tool_use_id, updated);
          this.emit({ type: "toolActivity", tool: updated });
        }
        break;
      }
      case "result": {
        if (Array.isArray(object.permission_denials) && object.permission_denials.length > 0) {
          this.emit({ type: "activity", text: `Claude declined ${object.permission_denials.length} operation(s) under its permission policy.` });
        }
        if (object.is_error === true) {
          const errors = Array.isArray(object.errors) && object.errors.every((e) => typeof e === "string") ? (object.errors as string[]).join("\n") : undefined;
          this.end({ type: "failed", text: AgentToolDetails.text(str(object.result) ?? errors ?? "Claude reported an error.") }, true);
        } else this.end({ type: "finished" }, true);
        break;
      }
      case "system": {
        if (object.subtype === "init" && typeof object.permissionMode === "string") {
          const mode = object.permissionMode;
          const normalized = mode === "manual" ? "default" : mode;
          const previous = this.confirmedPermissionMode === "manual" ? "default" : this.confirmedPermissionMode;
          if (previous !== undefined && normalized !== previous) {
            this.emit({ type: "interactionUnavailable", text: `Claude changed its permission mode to ${AgentToolDetails.text(mode, 80)}. Its model and managed permission policies remain authoritative.` });
          }
          this.confirmedPermissionMode = normalized;
        }
        if (object.subtype === "status") {
          if (object.status === "compacting") this.compact("compacting");
          else if (this.compaction?.state === "compacting" && typeof object.compact_result === "string") {
            this.compact(object.compact_result === "success" ? "completed" : "interrupted");
          }
        } else if (object.subtype === "compact_boundary") {
          // Completes a reported compaction, or one from a CLI that sent no status (e.g. a manual /compact).
          if (!this.compaction || this.compaction.state === "compacting") this.compact("completed");
          this.emit({ type: "activity", text: "Claude compacted the conversation." });
        }
        break;
      }
      case "rate_limit_event": {
        const usage = decodeClaudeRateLimit(isObject(object.rate_limit_info) ? object.rate_limit_info : {});
        if (usage) this.emit({ type: "usage", usage });
        break;
      }
    }
  }

  /** One query in flight per turn; responses that arrive meanwhile schedule a single follow-up. */
  private refreshContext(): void {
    const client = this.connection, session = this.remoteSession;
    if (!client || !session) return;
    if (this.contextQueryActive) { this.contextQueryPending = true; return; }
    this.contextQueryActive = true;
    const owner = this.generation;
    void this.reportContext(client, session).then(() => {
      if (this.generation !== owner) return;
      this.contextQueryActive = false;
      if (this.contextQueryPending) { this.contextQueryPending = false; this.refreshContext(); }
    });
  }

  private async reportContext(client: ClaudeConnection, session: string): Promise<void> {
    const epoch = ++this.contextEpoch;
    let response: JSONObject;
    try { response = await client.request({ subtype: "get_context_usage" }, 10_000); } catch { return; }
    const totals = ClaudeTranscriptUsage.sessionTotals(session, this.projectsDirectory);
    const usage = decodeClaudeContextUsage(response, totals);
    if (epoch !== this.contextEpoch || !usage) return;
    this.emit({ type: "conversationUsage", usage });
  }

  private compact(state: ContextCompaction["state"]): void {
    const current = this.compaction?.state === "compacting" ? this.compaction : undefined;
    if (state === "compacting" && current) return;
    const next: ContextCompaction = current ? { ...current, state } : { id: `${this.generation}:${newID()}`, state, startedAt: Date.now() };
    if (state !== "compacting") next.endedAt = Date.now();
    this.compaction = next;
    this.emit({ type: "compaction", compaction: next });
    if (state === "completed") this.refreshContext();
  }

  private stream(event: JSONObject): void {
    if (event.type === "message_start") { this.streamedBlocks.clear(); this.thinkingBlocks.clear(); }
    if (event.type === "content_block_start" && isObject(event.content_block) && event.content_block.type === "tool_use") this.startTool(event.content_block);
    const delta = isObject(event.delta) ? event.delta : undefined;
    if (!delta || typeof event.index !== "number") return;
    if (delta.type === "text_delta" && typeof delta.text === "string") {
      this.streamedBlocks.add(event.index); this.emit({ type: "textDelta", text: delta.text });
    } else if (delta.type === "thinking_delta" && typeof delta.thinking === "string") {
      this.thinkingBlocks.add(event.index); this.emit({ type: "reasoningDelta", text: delta.thinking });
    }
  }

  private startTool(block: JSONObject): void {
    if (typeof block.id !== "string" || this.tools.has(block.id)) return;
    const name = AgentToolDetails.text(str(block.name) ?? "Tool", 128);
    const tool: ToolActivity = { id: `${this.generation}:${block.id}`, server: "Claude", tool: name, state: "running", detail: "" };
    this.tools.set(block.id, tool);
    this.emit({ type: "toolActivity", tool });
  }

  private controlRequest(object: JSONObject): void {
    const id = str(object.request_id);
    const request = isObject(object.request) ? object.request : undefined;
    const client = this.connection;
    if (!id || this.seenRequests.has(id) || !request || !client) return;
    this.seenRequests.add(id);
    const name = str(request.tool_name);
    const input = isObject(request.input) ? request.input : undefined;
    if (!this.ready || request.subtype !== "can_use_tool" || !name || !input) {
      try { client.reject(id, "Octo does not support this Claude control request."); } catch { /* gone */ }
      this.emit({ type: "interactionUnavailable", text: "Unsupported Claude control request declined." });
      return;
    }
    if (name === "AskUserQuestion") {
      const interaction = ClaudeHarness.question(input);
      if (!interaction) {
        try { client.respond(id, { behavior: "deny", message: "Octo supports bounded single-choice questions only." }); } catch { /* gone */ }
        this.emit({ type: "interactionUnavailable", text: "Claude question declined: this question format is unsupported." });
        return;
      }
      this.questions.set(interaction.id, { requestID: id, input, interaction });
      this.emit({ type: "interaction", interaction });
      return;
    }
    const localID = newID(), owner = this.generation;
    this.approvals.set(id, { localID, input });
    const details = [request.description, request.decision_reason, request.blocked_path].filter((v): v is string => typeof v === "string");
    // These values are necessary to review the operation; never dump the full input.
    if (name === "Bash" && typeof input.command === "string") details.push(input.command);
    if (typeof input.file_path === "string") details.push(input.file_path);
    const detail = AgentToolDetails.text(details.length === 0 ? `Claude requests permission to use ${name}. This approval applies to this operation only.` : details.join("\n"));
    this.emit({
      type: "approval",
      approval: {
        id: localID, title: AgentToolDetails.text(`${name} approval`, 160), detail,
        respond: (allow) => {
          const pending = this.approvals.get(id);
          const current = this.connection;
          if (!this.active || this.generation !== owner || !pending || !current) return;
          try {
            current.respond(id, allow ? { behavior: "allow", updatedInput: pending.input } : { behavior: "deny", message: "The user declined this operation in Octo." });
            this.resolve(id);
          } catch (error) { this.end({ type: "failed", text: (error as Error).message }); }
        },
      },
    });
  }

  static question(input: JSONObject): AgentInteraction | undefined {
    const questions = input.questions;
    if (!Array.isArray(questions) || questions.length < 1 || questions.length > 4) return undefined;
    const fields: InteractionField[] = [];
    const seen = new Set<string>();
    for (const question of questions) {
      if (!isObject(question) || (question.multiSelect !== undefined && question.multiSelect !== false)) return undefined;
      const text = question.question, options = question.options;
      if (typeof text !== "string" || text === "" || Array.from(text).length > 2048 || seen.has(text) ||
          !Array.isArray(options) || options.length < 2 || options.length > 8) return undefined;
      seen.add(text);
      const labels = new Set<string>();
      const choices = [];
      for (const option of options) {
        if (!isObject(option) || typeof option.label !== "string" || option.label === "" || Array.from(option.label).length > 256 || labels.has(option.label)) return undefined;
        labels.add(option.label);
        choices.push({ id: option.label, label: option.label, detail: AgentToolDetails.text(str(option.description) ?? "", 1024) });
      }
      fields.push(makeField({ id: text, label: text, kind: "choice", required: true, options: choices, allowsOther: true, minLength: 1 }));
    }
    return makeInteraction({
      title: "Claude has a question", detail: "Choose an answer or enter your own.", fields, canDecline: true,
      cancellationDetail: "Cancel declines this question; it does not approve a tool.",
    });
  }

  respond(id: string, response: AgentInteractionResponse): void {
    const question = this.questions.get(id), client = this.connection;
    if (!this.active || !question || !client) throw new ProcessFailure("exited", "This Claude question is no longer active.");
    let reply: JSONObject;
    if (response.type === "submit") {
      const error = interactionValidationError(question.interaction, response.values);
      if (error) throw new ProcessFailure("exited", error);
      const answers: Record<string, string> = {};
      for (const [key, value] of Object.entries(response.values)) if (value.kind === "text") answers[key] = value.value;
      reply = { behavior: "allow", updatedInput: { ...question.input, answers } };
    } else {
      reply = { behavior: "deny", message: "The user declined this question in Octo." };
    }
    client.respond(question.requestID, reply);
    this.resolve(question.requestID);
  }

  private resolve(requestID: string): void {
    const approval = this.approvals.get(requestID);
    if (approval) { this.approvals.delete(requestID); this.emit({ type: "approvalResolved", id: approval.localID }); }
    for (const [id, question] of [...this.questions]) {
      if (question.requestID === requestID) { this.questions.delete(id); this.emit({ type: "interactionResolved", id }); }
    }
  }

  private invalidateRequests(): void {
    const approvalIDs = [...this.approvals.values()].map((a) => a.localID), questionIDs = [...this.questions.keys()];
    this.approvals.clear(); this.questions.clear();
    for (const id of approvalIDs) this.emit({ type: "approvalResolved", id });
    for (const id of questionIDs) this.emit({ type: "interactionResolved", id });
  }

  private end(event: AgentEvent, reportContext = false): void {
    if (!this.active) return;
    this.active = false; this.ready = false; this.invalidateRequests();
    for (const [id, tool] of this.tools) {
      if (tool.state !== "running") continue;
      const ended = { ...tool, state: "interrupted" as const };
      this.tools.set(id, ended);
      this.emit({ type: "toolActivity", tool: ended });
    }
    if (this.compaction?.state === "compacting") {
      this.compaction = { ...this.compaction, state: "interrupted", endedAt: Date.now() };
      this.emit({ type: "compaction", compaction: this.compaction });
    }
    const client = this.connection;
    this.connection = undefined;
    const session = this.remoteSession;
    if (reportContext && client && session) {
      // Final accounting arrives after the result, like Codex's late usage notification.
      this.draining?.close();
      this.draining = client;
      void this.reportContext(client, session).then(() => {
        if (event.type === "finished") client.finish(); else client.close();
        if (this.draining === client) this.draining = undefined;
      });
    } else if (event.type === "finished") client?.finish();
    else client?.close();
    this.emit(event);
  }

  async steer(): Promise<void> {
    throw new ProcessFailure("exited", "Steering is unavailable in this adapter. Queue a follow-up instead.");
  }

  async interrupt(): Promise<void> {
    this.startup?.abort();
    this.end({ type: "interrupted" });
  }

  shutdown(): void {
    this.startup?.abort();
    if (this.active) this.end({ type: "interrupted" });
    this.connection?.close(); this.connection = undefined;
    this.draining?.close(); this.draining = undefined;
    this.generation = newID();
  }
}
