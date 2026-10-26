import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { makeArchive, makeMessage, makeProject, makeThread, toolActivityText, type ContextCompaction } from "@octo/core";
import { makeInteraction, type AgentModel } from "@octo/agents";
import { WorkspaceStore } from "@octo/core/node";
import { makeStore, removeRoot, settle, temporaryRoot } from "./fixtures";

const roots: string[] = [];
const root = () => { const r = temporaryRoot(); roots.push(r); return r; };
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe("Interaction and usage routing", () => {
  it("keeps interactions and tool activity with their owning thread and persists them", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const first = makeThread({ workingDirectory: directory }); first.messages = [makeMessage("user", "One")];
    const second = makeThread({ workingDirectory: directory }); second.messages = [makeMessage("user", "Two")];
    const project = makeProject({ name: "Fixtures", rootPath: directory, threads: [first, second] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: second.id }));
    store.beginWork(first.id); store.beginWork(second.id);
    const request = makeInteraction({ title: "Request", detail: "Fixture", target: "Safari", fields: [], canDecline: true, cancellationDetail: "Cancel" });
    store.handle({ type: "interaction", interaction: request }, first.id);
    store.handle({ type: "interaction", interaction: request }, first.id);
    expect(store.s.interactions[first.id].length).toBe(1);
    expect(store.s.interactions[second.id]).toBeUndefined();
    expect(store.respond(request.id, second.id, { type: "cancel" })).toBeDefined();
    let tool = { id: "connection:turn:call", server: "fixture", tool: "test", state: "running" as "running" | "completed", detail: "" };
    store.handle({ type: "toolActivity", tool }, first.id);
    store.handle({ type: "toolActivity", tool }, first.id);
    store.handle({ type: "activityDelta", text: "Independent commentary" }, first.id);
    tool = { ...tool, state: "completed", detail: "Done" };
    store.handle({ type: "toolActivity", tool }, first.id);
    store.handle({ type: "toolActivity", tool }, first.id);
    expect(store.archive.projects[0].threads[0].messages.length).toBe(3);
    expect(store.archive.projects[0].threads[0].messages[1].text).toBe(toolActivityText(tool));
    expect(store.thread!.messages.length).toBe(1);
    store.handle({ type: "interactionResolved", id: request.id }, first.id);
    expect(store.s.interactions[first.id].length).toBe(0);
    store.handle({ type: "interaction", interaction: request }, second.id);
    store.handle({ type: "failed", text: "Transport disconnected" }, second.id);
    expect(store.s.interactions[second.id].length).toBe(0);
    store.handle({ type: "interactionUnavailable", text: "Unsupported form" }, first.id);
    expect(store.archive.projects[0].threads[0].messages.at(-1)?.role).toBe("error");
    store.handle({ type: "finished" }, first.id);
    await store.saveNow();
    const reloaded = await storage.load();
    expect(reloaded.projects[0].threads[0].messages[1].toolActivity).toEqual(tool);
    reloaded.projects[0].threads[0].messages[1].toolActivity!.state = "running";
    await store.shutdown();
    await storage.save(reloaded);
    const { store: restarted } = await makeStore(directory);
    expect(restarted.archive.projects[0].threads[0].messages[1].toolActivity?.state).toBe("interrupted");
    await restarted.shutdown();
  });

  it("replaces usage snapshots, persists them and keeps them with the owning thread", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const first = makeThread({ workingDirectory: directory }), second = makeThread({ harness: "claude", workingDirectory: directory });
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [first, second] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: second.id }));
    const initial = { latest: { total: 180_000 }, session: { total: 800_000 }, contextWindow: 200_000, updatedAt: Date.now() };
    store.handle({ type: "conversationUsage", usage: initial }, first.id);
    store.handle({ type: "conversationUsage", usage: initial }, first.id);
    expect(store.thread?.conversationUsage).toBeUndefined();
    expect(store.archive.projects[0].threads[0].conversationUsage).toEqual(initial);
    const reduced = { latest: { total: 30_000 }, session: { total: 40_000 }, updatedAt: Date.now() };
    store.handle({ type: "conversationUsage", usage: reduced }, first.id);
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].conversationUsage).toEqual(reduced);
    await store.changeHarness("codex");
    expect(store.thread?.conversationUsage).toBeUndefined();
    await store.shutdown();
  });

  it("tracks compaction through stop, failure, relaunch and completion", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory }); thread.messages = [makeMessage("user", "Fixture")];
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    let compaction: ContextCompaction = { id: "one", state: "compacting", startedAt: Date.now() };
    store.handle({ type: "compaction", compaction }, thread.id);
    expect(store.thread?.lastCompaction).toBeUndefined();
    store.beginWork(thread.id);
    store.handle({ type: "compaction", compaction }, thread.id);
    store.handle({ type: "compaction", compaction }, thread.id);
    store.stop(thread.id);
    expect(store.thread?.lastCompaction?.state).toBe("interrupted");
    store.handle({ type: "compaction", compaction: { ...compaction, state: "completed" } }, thread.id);
    expect(store.thread?.lastCompaction?.state).toBe("interrupted");
    store.handle({ type: "finished" }, thread.id);
    store.beginWork(thread.id);
    compaction = { id: "two", state: "compacting", startedAt: Date.now() };
    store.handle({ type: "compaction", compaction }, thread.id);
    store.handle({ type: "failed", text: "Disconnected" }, thread.id);
    expect(store.thread?.lastCompaction?.state).toBe("interrupted");
    store.beginWork(thread.id);
    compaction = { id: "three", state: "compacting", startedAt: Date.now() };
    store.handle({ type: "compaction", compaction }, thread.id);
    compaction = { ...compaction, state: "completed", endedAt: Date.now() };
    store.handle({ type: "compaction", compaction }, thread.id);
    store.handle({ type: "finished" }, thread.id);
    expect(store.thread?.lastCompaction).toEqual(compaction);
    await store.saveNow();
    const archive = await storage.load();
    expect(archive.projects[0].threads[0].lastCompaction).toEqual(compaction);
    archive.projects[0].threads[0].lastCompaction!.state = "compacting";
    await store.shutdown();
    await storage.save(archive);
    const { store: restarted } = await makeStore(directory);
    expect(restarted.thread?.lastCompaction?.state).toBe("interrupted");
    await restarted.shutdown();
  });
});

describe("Thread titles", () => {
  async function fixture(generator: (id: string, text: string) => Promise<string | undefined>) {
    const directory = root();
    const { WorkspaceStore: Store } = await import("@octo/core/node");
    const { AppStore } = await import("../appStore");
    const { PreferencesFile } = await import("../preferences");
    const { FakePlatform, fixtureExecutables } = await import("./fixtures");
    const storage = new Store(join(directory, "data", "workspace.json"));
    const store = new AppStore({ storage, preferences: new PreferencesFile(directory), platform: new FakePlatform(), titleGenerator: generator, resolveExecutables: fixtureExecutables });
    await store.load();
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    return { store, storage, directory };
  }
  const prepare = (store: Awaited<ReturnType<typeof fixture>>["store"], text: string) =>
    (store as unknown as { prepareThreadTitle(t: unknown, text: string): void }).prepareThreadTitle(store.thread, text);

  it("uses the first text, persists, and never changes conversation settings", async () => {
    let input = "";
    const { store, storage } = await fixture(async (provider, text) => { expect(provider).toBe("codex"); input = text; return "Improve sidebar navigation"; });
    store.state.update((d) => { d.archive.projects[0].threads[0].agentSettings = { model: "chat-model", reasoningEffort: "high" }; });
    const settings = store.thread!.agentSettings;
    prepare(store, "a".repeat(5_000));
    expect(store.thread?.title).toBe("a".repeat(52));
    await sleep(20);
    expect(input.length).toBe(4_000);
    expect(store.thread?.title).toBe("Improve sidebar navigation");
    expect(store.thread?.agentSettings).toEqual(settings);
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].title).toBe("Improve sidebar navigation");
    await store.shutdown();
  });

  it("keeps the fallback for empty text, failures and existing chats", async () => {
    let calls = 0;
    const { store, directory } = await fixture(async () => { calls++; throw new Error("timed out"); });
    store.state.update((d) => { d.archive.projects[0].threads[0].harness = "claude"; });
    prepare(store, "First message");
    await sleep(20); expect(calls).toBe(1); expect(store.thread?.title).toBe("First message");
    const fresh = makeThread({ workingDirectory: directory });
    store.state.update((d) => { d.archive.projects[0].threads[0] = fresh; d.archive.selectedThreadID = fresh.id; });
    prepare(store, "");
    await sleep(20); expect(calls).toBe(1); expect(store.thread?.title).toBe("Screenshot discussion");
    store.state.update((d) => { d.archive.projects[0].threads[0].title = "New thread"; });
    prepare(store, "Failed generation fallback");
    await sleep(20); expect(calls).toBe(2); expect(store.thread?.title).toBe("Failed generation fallback");
    store.state.update((d) => { d.archive.projects[0].threads[0].title = "New thread"; d.archive.projects[0].threads[0].messages = [makeMessage("user", "Existing")]; });
    prepare(store, "Don't rename history");
    await sleep(20); expect(calls).toBe(2);
    await store.shutdown();
  });

  it("never lets a late result overwrite a manual rename or recreate a deleted thread", async () => {
    let complete = undefined as ((title: string) => void) | undefined;
    const { store, storage, directory } = await fixture(() => new Promise((resolve) => { complete = resolve; }));
    const id = store.thread!.id;
    prepare(store, "Original fallback");
    await settle();
    store.renameThread(id, "Original fallback");
    (complete as ((title: string) => void) | undefined)?.("Late automatic title"); complete = undefined;
    await settle();
    expect(store.thread?.title).toBe("Original fallback");
    expect(store.thread?.isTitleManuallySet).toBe(true);
    await store.saveNow(); expect((await storage.load()).projects[0].threads[0].isTitleManuallySet).toBe(true);
    const fresh = makeThread({ workingDirectory: directory });
    store.state.update((d) => { d.archive.projects[0].threads[0] = fresh; d.archive.selectedThreadID = fresh.id; });
    prepare(store, "Delete me");
    await settle();
    store.deleteThread(store.thread!.id, store.project!.id);
    (complete as ((title: string) => void) | undefined)?.("Must not reappear"); complete = undefined;
    await settle(); expect(store.archive.projects[0].threads).toEqual([]);
    await store.shutdown();
  });

  it("rejects a late title after shutdown", async () => {
    let complete = undefined as ((title: string) => void) | undefined;
    const { store } = await fixture(() => new Promise((resolve) => { complete = resolve; }));
    prepare(store, "Keep fallback");
    await settle(); await store.shutdown();
    (complete as ((title: string) => void) | undefined)?.("Too late"); await settle();
    expect(store.thread?.title).toBe("Keep fallback");
  });
});

describe("Claude settings", () => {
  const catalog = (names: string[], effort = "medium"): AgentModel[] => names.map((name) => ({
    model: name, displayName: name, description: "", hidden: false, isDefault: false, defaultReasoningEffort: effort,
    supportedReasoningEfforts: effort ? [{ reasoningEffort: effort, description: "" }] : [],
  }));

  it("defaults to Auto, keeps an explicit Manual choice and remembers it for new chats", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    await store.changeHarness("claude");
    const descriptor = store.harnessDescriptors().find((d) => d.id === "claude")!;
    expect(descriptor.defaultPermissionMode).toBe("autoReview");
    expect(descriptor.permissionOptions.map((o) => o.title)).toEqual(["Manual", "Auto"]);
    const id = store.thread!.id;
    store.selectPermissions("autoReview", id);
    store.beginWork(id); store.selectPermissions("ask", id);
    expect(store.thread?.agentSettings.permissionMode).toBe("autoReview");
    store.handle({ type: "interrupted" }, id); store.selectPermissions("ask", id);
    await store.shutdown();
    const { store: reloaded } = await makeStore(directory);
    expect(reloaded.thread?.agentSettings.permissionMode).toBe("ask");
    await reloaded.newThread({ harness: "claude" });
    expect(reloaded.thread?.agentSettings.permissionMode).toBe("ask");
    reloaded.selectPermissions("autoReview", reloaded.thread!.id);
    await reloaded.newThread({ harness: "claude" });
    expect(reloaded.thread?.agentSettings.permissionMode).toBe("autoReview");
    await reloaded.saveNow();
    expect((await storage.load()).rememberedAgentSettings?.claude?.permissionMode).toBe("autoReview");
    expect(store.harnessDescriptors().find((d) => d.id === "codex")?.defaultPermissionMode).toBe("ask");
    await reloaded.shutdown();
  });

  it("isolates provider catalogs, keeps effort defaults and persists choices", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const thread = makeThread({ harness: "claude", workingDirectory: directory });
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    const models = [...catalog(["sonnet"], "").map((m) => ({ ...m, supportedReasoningEfforts: [{ reasoningEffort: "high", description: "" }] })), ...catalog(["haiku"], "")];
    store.state.update((d) => { d.modelCatalogs[`claude:${directory}`] = models; });
    store.selectModel("sonnet"); store.selectReasoning("high");
    expect(store.thread?.agentSettings).toEqual({ model: "sonnet", reasoningEffort: "high" });
    store.beginWork(thread.id); store.selectModel("haiku"); store.selectReasoning("low");
    expect(store.thread?.agentSettings.model).toBe("sonnet");
    store.handle({ type: "interrupted" }, thread.id); store.selectModel("haiku");
    expect(store.thread?.agentSettings.reasoningEffort).toBeUndefined();
    store.selectPermissions("readOnly", thread.id);
    expect(store.thread?.agentSettings.permissionMode).toBeUndefined();
    store.selectPermissions("ask", thread.id);
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].agentSettings).toEqual({ model: "haiku", permissionMode: "ask" });
    await store.changeHarness("codex");
    store.selectModel("sonnet");
    expect(store.thread?.agentSettings.model).toBeUndefined();
    await store.changeHarness("claude");
    expect(store.thread?.agentSettings.model).toBe("haiku");
    store.state.update((d) => { d.archive.projects[0].threads[0].agentSettings.model = "removed-model"; });
    expect(await store.send(thread.id, "Keep this draft")).toBe(false);
    expect(store.s.running).toEqual([]);
    expect(store.s.error).toContain("unavailable");
    await store.shutdown();
  });

  it("keeps the thread for model changes and branches only for a provider with history", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const thread = makeThread({ harness: "claude", workingDirectory: directory }); thread.messages = [makeMessage("user", "Started on Claude")];
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.state.update((d) => { d.modelCatalogs[`claude:${directory}`] = catalog(["sonnet", "opus"]); d.modelCatalogs[`codex:${directory}`] = catalog(["gpt-5.5"]); });
    await store.selectAgent("claude", "opus");
    expect(store.thread?.id).toBe(thread.id);
    expect(store.thread?.agentSettings.model).toBe("opus");
    await store.selectAgent("codex", "gpt-5.5");
    expect(store.thread?.id).not.toBe(thread.id);
    expect(store.thread?.harness).toBe("codex");
    expect(store.thread?.agentSettings.model).toBe("gpt-5.5");
    expect(store.archive.projects[0].threads.find((t) => t.id === thread.id)?.harness).toBe("claude");
    const draft = store.thread!.id;
    await store.selectAgent("claude", "sonnet");
    expect(store.thread?.id).toBe(draft);
    expect(store.thread?.harness).toBe("claude");
    expect(store.thread?.agentSettings.model).toBe("sonnet");
    await store.selectAgent("claude", "gpt-5.5");
    expect(store.thread?.agentSettings.model).toBe("sonnet");
    await store.shutdown();
  });
});

void WorkspaceStore;
