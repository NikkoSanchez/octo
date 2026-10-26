// The workspace archive on disk is schema-v1 JSON: dates are seconds since 2001-01-01, binary data
// is base64, enums with payloads use `{"case":{"_0":…}}`, and dictionaries keyed by UUID are flat
// `[key, value, key, value]` arrays. New fields must be optional so older archives keep decoding.
import type { BrowserAnnotation } from "./browserAnnotation";
import type { ContextCompaction, ConversationUsage, TokenCounts } from "./conversationUsage";
import { fromArchiveDate, toArchiveDate } from "./dates";
import { normalizeUUID, isUUID } from "./ids";
import { createPanelTabs, tabsEqual, type PanelTab, type PanelTabs } from "./panelTabs";
import type { LineRange } from "./range";
import type { CodeAttachment, DiffScope } from "./review";
import type { ToolActivity } from "./toolActivity";
import {
  PERMISSION_MODES, type AgentPermissionMode, type AgentSettings, type ChatMessage, type HarnessID, type ImageAttachment,
  type MessageRole, type TurnWork, type WorkspaceArchive, type WorkspaceProject, type WorkspaceThread,
} from "./workspace";

export class ArchiveDecodingError extends Error {}

type JSONObject = Record<string, unknown>;

function object(value: unknown, what: string): JSONObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new ArchiveDecodingError(`Expected ${what} object`);
  return value as JSONObject;
}
function string(value: unknown, what: string): string {
  if (typeof value !== "string") throw new ArchiveDecodingError(`Expected ${what} string`);
  return value;
}
function optionalString(value: unknown, what: string): string | undefined {
  return value === undefined || value === null ? undefined : string(value, what);
}
function number(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new ArchiveDecodingError(`Expected ${what} number`);
  return value;
}
function optionalNumber(value: unknown, what: string): number | undefined {
  return value === undefined || value === null ? undefined : number(value, what);
}
function integer(value: unknown, what: string): number {
  const n = number(value, what);
  if (!Number.isInteger(n)) throw new ArchiveDecodingError(`Expected ${what} integer`);
  return n;
}
function optionalInteger(value: unknown, what: string): number | undefined {
  return value === undefined || value === null ? undefined : integer(value, what);
}
function bool(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}
function date(value: unknown, what: string): number {
  try { return fromArchiveDate(value); } catch { throw new ArchiveDecodingError(`Expected ${what} date`); }
}
function optionalDate(value: unknown, what: string): number | undefined {
  return value === undefined || value === null ? undefined : date(value, what);
}
function uuid(value: unknown, what: string): string {
  try { return normalizeUUID(value); } catch { throw new ArchiveDecodingError(`Expected ${what} UUID`); }
}
function optionalUUID(value: unknown, what: string): string | undefined {
  return value === undefined || value === null ? undefined : uuid(value, what);
}
function array(value: unknown, what: string): unknown[] {
  if (!Array.isArray(value)) throw new ArchiveDecodingError(`Expected ${what} array`);
  return value;
}
function oneOf<T extends string>(value: unknown, allowed: readonly T[], what: string): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) throw new ArchiveDecodingError(`Unknown ${what} ${JSON.stringify(value)}`);
  return value as T;
}
/** Drops undefined values so encoded JSON omits absent fields. */
function compact<T extends JSONObject>(value: T): T {
  for (const key of Object.keys(value)) if (value[key] === undefined) delete value[key];
  return value;
}

// MARK: Leaves

const ROLES: readonly MessageRole[] = ["user", "assistant", "activity", "reasoning", "error"];
const SCOPES: readonly DiffScope[] = ["working", "staged", "file"];
const HARNESSES: readonly HarnessID[] = ["codex", "claude"];

function decodeTokenCounts(value: unknown): TokenCounts {
  const o = object(value, "token counts");
  return compact({
    total: integer(o.total, "total"), input: optionalInteger(o.input, "input"), cachedInput: optionalInteger(o.cachedInput, "cachedInput"),
    cacheWriteInput: optionalInteger(o.cacheWriteInput, "cacheWriteInput"), output: optionalInteger(o.output, "output"),
    reasoning: optionalInteger(o.reasoning, "reasoning"),
  });
}

function decodeUsage(value: unknown): ConversationUsage {
  const o = object(value, "usage");
  return compact({
    latest: decodeTokenCounts(o.latest),
    session: o.session === undefined || o.session === null ? undefined : decodeTokenCounts(o.session),
    contextWindow: optionalInteger(o.contextWindow, "contextWindow"),
    contextTokens: optionalInteger(o.contextTokens, "contextTokens"),
    autoCompactThreshold: optionalInteger(o.autoCompactThreshold, "autoCompactThreshold"),
    updatedAt: date(o.updatedAt, "updatedAt"),
  });
}
function encodeUsage(u: ConversationUsage): JSONObject {
  return compact({ ...u, latest: { ...u.latest }, session: u.session ? { ...u.session } : undefined, updatedAt: toArchiveDate(u.updatedAt) });
}

function decodeCompaction(value: unknown): ContextCompaction {
  const o = object(value, "compaction");
  return compact({
    id: string(o.id, "compaction id"),
    state: oneOf(o.state, ["compacting", "completed", "interrupted"] as const, "compaction state"),
    startedAt: date(o.startedAt, "startedAt"), endedAt: optionalDate(o.endedAt, "endedAt"),
  });
}
function encodeCompaction(c: ContextCompaction): JSONObject {
  return compact({ id: c.id, state: c.state, startedAt: toArchiveDate(c.startedAt), endedAt: c.endedAt === undefined ? undefined : toArchiveDate(c.endedAt) });
}

function decodeLines(value: unknown): LineRange | undefined {
  if (value === undefined || value === null) return undefined;
  const pair = array(value, "line range");
  if (pair.length !== 2) throw new ArchiveDecodingError("Expected a closed range");
  const lower = integer(pair[0], "lower"), upper = integer(pair[1], "upper");
  if (upper < lower) throw new ArchiveDecodingError("Range requires lower <= upper");
  return [lower, upper];
}

function decodeAttachment(value: unknown): CodeAttachment {
  const o = object(value, "code attachment");
  return compact({
    id: uuid(o.id, "attachment id"), projectID: uuid(o.projectID, "projectID"),
    workingDirectory: string(o.workingDirectory, "workingDirectory"), path: string(o.path, "path"),
    snapshotID: string(o.snapshotID, "snapshotID"), baseRevision: string(o.baseRevision, "baseRevision"),
    scope: oneOf(o.scope, SCOPES, "scope"), oldLines: decodeLines(o.oldLines), newLines: decodeLines(o.newLines),
    text: string(o.text, "text"),
  });
}
function encodeAttachment(a: CodeAttachment): JSONObject {
  return compact({ ...a, oldLines: a.oldLines ? [...a.oldLines] : undefined, newLines: a.newLines ? [...a.newLines] : undefined });
}

function decodeImage(value: unknown): ImageAttachment {
  const o = object(value, "image");
  return { id: uuid(o.id, "image id"), name: string(o.name, "image name"), pngBase64: string(o.pngData, "pngData") };
}
function encodeImage(i: ImageAttachment): JSONObject {
  return { id: i.id, name: i.name, pngData: i.pngBase64 };
}

function decodeAnnotation(value: unknown): BrowserAnnotation {
  const o = object(value, "annotation");
  const rect = object(o.rect, "rect"), viewport = object(o.viewport, "viewport");
  return compact({
    id: uuid(o.id, "annotation id"), kind: oneOf(o.kind, ["element", "region"] as const, "annotation kind"),
    url: string(o.url, "url"), pageTitle: string(o.pageTitle, "pageTitle"), selector: string(o.selector, "selector"),
    element: string(o.element, "element"), text: string(o.text, "text"), html: string(o.html, "html"),
    rect: { x: number(rect.x, "x"), y: number(rect.y, "y"), width: number(rect.width, "width"), height: number(rect.height, "height") },
    viewport: { width: number(viewport.width, "width"), height: number(viewport.height, "height") },
    screenshot: optionalString(o.screenshot, "screenshot"),
  });
}
function encodeAnnotation(a: BrowserAnnotation): JSONObject {
  return compact({ ...a, rect: { ...a.rect }, viewport: { ...a.viewport } });
}

function decodeTool(value: unknown): ToolActivity {
  const o = object(value, "tool activity");
  return {
    id: string(o.id, "tool id"), server: string(o.server, "server"), tool: string(o.tool, "tool"),
    state: oneOf(o.state, ["running", "completed", "failed", "interrupted"] as const, "tool state"), detail: string(o.detail, "detail"),
  };
}

function decodeWork(value: unknown): TurnWork {
  const o = object(value, "turn work");
  return compact({
    startedAt: date(o.startedAt, "startedAt"), elapsed: optionalNumber(o.elapsed, "elapsed"),
    outcome: o.outcome === undefined || o.outcome === null ? undefined : oneOf(o.outcome, ["completed", "stopped", "failed", "interrupted"] as const, "outcome"),
  });
}
function encodeWork(w: TurnWork): JSONObject {
  return compact({ startedAt: toArchiveDate(w.startedAt), elapsed: w.elapsed, outcome: w.outcome });
}

export function decodeMessage(value: unknown): ChatMessage {
  const o = object(value, "message");
  return compact({
    id: uuid(o.id, "message id"), role: oneOf(o.role, ROLES, "role"), text: string(o.text, "text"),
    attachments: array(o.attachments, "attachments").map(decodeAttachment),
    images: o.images === undefined || o.images === null ? [] : array(o.images, "images").map(decodeImage),
    browserAnnotations: o.browserAnnotations === undefined || o.browserAnnotations === null ? [] : array(o.browserAnnotations, "browserAnnotations").map(decodeAnnotation),
    createdAt: date(o.createdAt, "createdAt"), completedAt: optionalDate(o.completedAt, "completedAt"),
    work: o.work === undefined || o.work === null ? undefined : decodeWork(o.work),
    toolActivity: o.toolActivity === undefined || o.toolActivity === null ? undefined : decodeTool(o.toolActivity),
    isSteering: typeof o.isSteering === "boolean" ? o.isSteering : undefined,
  });
}

export function encodeMessage(m: ChatMessage): JSONObject {
  return compact({
    id: m.id, role: m.role, text: m.text, attachments: m.attachments.map(encodeAttachment), images: m.images.map(encodeImage),
    browserAnnotations: m.browserAnnotations.map(encodeAnnotation), createdAt: toArchiveDate(m.createdAt),
    completedAt: m.completedAt === undefined ? undefined : toArchiveDate(m.completedAt),
    work: m.work ? encodeWork(m.work) : undefined, toolActivity: m.toolActivity ? { ...m.toolActivity } : undefined,
    isSteering: m.isSteering,
  });
}

function decodeSettings(value: unknown): AgentSettings {
  const o = object(value, "agent settings");
  return compact({
    model: optionalString(o.model, "model"), reasoningEffort: optionalString(o.reasoningEffort, "reasoningEffort"),
    permissionMode: o.permissionMode === undefined || o.permissionMode === null ? undefined : oneOf(o.permissionMode, PERMISSION_MODES, "permission mode") as AgentPermissionMode,
  });
}

function decodeThread(value: unknown): WorkspaceThread {
  const o = object(value, "thread");
  return compact({
    id: uuid(o.id, "thread id"),
    agentSettings: o.agentSettings === undefined || o.agentSettings === null ? {} : decodeSettings(o.agentSettings),
    title: string(o.title, "title"), isTitleManuallySet: bool(o.isTitleManuallySet, false),
    harness: oneOf(o.harness, HARNESSES, "harness"), workingDirectory: string(o.workingDirectory, "workingDirectory"),
    remoteSessionID: optionalString(o.remoteSessionID, "remoteSessionID"),
    conversationUsage: o.conversationUsage === undefined || o.conversationUsage === null ? undefined : decodeUsage(o.conversationUsage),
    lastCompaction: o.lastCompaction === undefined || o.lastCompaction === null ? undefined : decodeCompaction(o.lastCompaction),
    lastVisitedAt: optionalDate(o.lastVisitedAt, "lastVisitedAt"), lastActivityAt: optionalDate(o.lastActivityAt, "lastActivityAt"),
    lastDraftedAt: optionalDate(o.lastDraftedAt, "lastDraftedAt"), unreadCompletedAt: optionalDate(o.unreadCompletedAt, "unreadCompletedAt"),
    messages: array(o.messages, "messages").map(decodeMessage), createdAt: date(o.createdAt, "createdAt"),
    isPinned: bool(o.isPinned, false),
  });
}

function encodeThread(t: WorkspaceThread): JSONObject {
  const archiveDate = (ms: number | undefined) => (ms === undefined ? undefined : toArchiveDate(ms));
  return compact({
    agentSettings: compact({ ...t.agentSettings }), id: t.id, title: t.title, isTitleManuallySet: t.isTitleManuallySet,
    harness: t.harness, workingDirectory: t.workingDirectory, remoteSessionID: t.remoteSessionID,
    messages: t.messages.map(encodeMessage), createdAt: toArchiveDate(t.createdAt), isPinned: t.isPinned,
    conversationUsage: t.conversationUsage ? encodeUsage(t.conversationUsage) : undefined,
    lastCompaction: t.lastCompaction ? encodeCompaction(t.lastCompaction) : undefined,
    lastVisitedAt: archiveDate(t.lastVisitedAt), lastActivityAt: archiveDate(t.lastActivityAt),
    lastDraftedAt: archiveDate(t.lastDraftedAt), unreadCompletedAt: archiveDate(t.unreadCompletedAt),
  });
}

// MARK: Panel tabs

function decodeTab(value: unknown): PanelTab | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const keys = Object.keys(value);
  if (keys.length !== 1) return undefined;
  const payload = (value as JSONObject)[keys[0]];
  switch (keys[0]) {
    case "changes": return { kind: "changes" };
    case "files": return { kind: "files" };
    case "file": {
      const path = (payload as JSONObject | null)?._0;
      return typeof path === "string" ? { kind: "file", path } : undefined;
    }
    case "browser": {
      const id = (payload as JSONObject | null)?._0;
      return isUUID(id) ? { kind: "browser", id: id.toUpperCase() } : undefined;
    }
    default: return undefined;
  }
}

function encodeTab(tab: PanelTab): JSONObject {
  switch (tab.kind) {
    case "changes": return { changes: {} };
    case "files": return { files: {} };
    case "file": return { file: { _0: tab.path } };
    case "browser": return { browser: { _0: tab.id } };
  }
}

/** Drops duplicates and unknown future cases rather than failing the whole archive. */
export function decodePanelTabs(value: unknown): PanelTabs {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return createPanelTabs();
  const o = value as JSONObject;
  const tabs: PanelTab[] = [];
  for (const raw of Array.isArray(o.tabs) ? o.tabs : []) {
    const tab = decodeTab(raw);
    if (tab && !tabs.some((t) => tabsEqual(t, tab))) tabs.push(tab);
  }
  const selected = decodeTab(o.selected);
  const chosen = selected && tabs.some((t) => tabsEqual(t, selected)) ? selected : (tabs[0] ?? null);
  const preview = typeof o.preview === "string" && tabs.some((t) => t.kind === "file" && t.path === o.preview) ? o.preview : null;
  const addresses: Record<string, string> = {};
  if (Array.isArray(o.browserAddresses)) {
    for (let i = 0; i + 1 < o.browserAddresses.length; i += 2) {
      const id = o.browserAddresses[i], address = o.browserAddresses[i + 1];
      if (isUUID(id) && typeof address === "string" && tabs.some((t) => t.kind === "browser" && t.id === id.toUpperCase())) addresses[id.toUpperCase()] = address;
    }
  }
  return {
    tabs, selected: chosen, preview, showsFileTree: typeof o.showsFileTree === "boolean" ? o.showsFileTree : true,
    browserAddresses: addresses, privateBrowsers: [],
    lastFile: chosen?.kind === "file" ? chosen.path : null, lastBrowser: chosen?.kind === "browser" ? chosen.id : null,
  };
}

export function encodePanelTabs(tabs: PanelTabs): JSONObject {
  const saved = tabs.tabs.filter((t) => t.kind !== "browser" || !tabs.privateBrowsers.includes(t.id));
  const selected = tabs.selected && saved.some((t) => tabsEqual(t, tabs.selected)) ? tabs.selected : saved[0];
  return compact({
    tabs: saved.map(encodeTab), selected: selected ? encodeTab(selected) : undefined, preview: tabs.preview ?? undefined,
    showsFileTree: tabs.showsFileTree, browserAddresses: Object.entries(tabs.browserAddresses).flat(),
  });
}

// MARK: Projects and archive

export function decodeProject(value: unknown): WorkspaceProject {
  const o = object(value, "project");
  return {
    id: uuid(o.id, "project id"), name: string(o.name, "name"), rootPath: string(o.rootPath, "rootPath"),
    threads: array(o.threads, "threads").map(decodeThread), isPinned: bool(o.isPinned, false),
    isCollapsed: bool(o.isCollapsed, false), isChatCollection: bool(o.isChatCollection, false),
    panelTabs: decodePanelTabs(o.panelTabs),
  };
}

function encodeProject(p: WorkspaceProject): JSONObject {
  return {
    id: p.id, name: p.name, rootPath: p.rootPath, threads: p.threads.map(encodeThread), isPinned: p.isPinned,
    isCollapsed: p.isCollapsed, isChatCollection: p.isChatCollection, panelTabs: encodePanelTabs(p.panelTabs),
  };
}

export function decodeArchive(value: unknown): WorkspaceArchive {
  const o = object(value, "archive");
  const remembered = o.rememberedAgentSettings === undefined || o.rememberedAgentSettings === null ? undefined
    : Object.fromEntries(Object.entries(object(o.rememberedAgentSettings, "remembered settings")).map(([k, v]) => [k, decodeSettings(v)]));
  return compact({
    lastHarness: o.lastHarness === undefined || o.lastHarness === null ? undefined : oneOf(o.lastHarness, HARNESSES, "harness"),
    rememberedAgentSettings: remembered,
    projectsSectionCollapsed: typeof o.projectsSectionCollapsed === "boolean" ? o.projectsSectionCollapsed : undefined,
    recentSectionCollapsed: typeof o.recentSectionCollapsed === "boolean" ? o.recentSectionCollapsed : undefined,
    schemaVersion: integer(o.schemaVersion, "schemaVersion"),
    projects: array(o.projects, "projects").map(decodeProject),
    selectedProjectID: optionalUUID(o.selectedProjectID, "selectedProjectID"),
    selectedThreadID: optionalUUID(o.selectedThreadID, "selectedThreadID"),
  });
}

export function encodeArchive(a: WorkspaceArchive): JSONObject {
  return compact({
    lastHarness: a.lastHarness,
    rememberedAgentSettings: a.rememberedAgentSettings
      ? Object.fromEntries(Object.entries(a.rememberedAgentSettings).map(([k, v]) => [k, compact({ ...v })])) : undefined,
    projectsSectionCollapsed: a.projectsSectionCollapsed, recentSectionCollapsed: a.recentSectionCollapsed,
    schemaVersion: a.schemaVersion, projects: a.projects.map(encodeProject),
    selectedProjectID: a.selectedProjectID, selectedThreadID: a.selectedThreadID,
  });
}

/** Sorted keys and two-space indentation. */
export function serializeArchive(archive: WorkspaceArchive): string {
  return JSON.stringify(sortKeys(encodeArchive(archive)), null, 2);
}

export function parseArchive(text: string): WorkspaceArchive {
  let value: unknown;
  try { value = JSON.parse(text); } catch (error) { throw new ArchiveDecodingError(`The workspace file is not valid JSON: ${(error as Error).message}`); }
  return decodeArchive(value);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys((value as JSONObject)[key])]));
  }
  return value;
}
