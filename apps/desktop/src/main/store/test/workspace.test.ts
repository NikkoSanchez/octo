import { existsSync, statSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  chatsProject, makeArchive, makeMessage, makeProject, makeSnapshot, makeThread, messageGroups, orderedProjects, recentThreads,
  ReviewDocument, searchableThreads, newID, type AgentSettings,
} from "@octo/core";
import type { AgentModel } from "@octo/agents";
import { WorkspaceStore } from "@octo/core/node";
import { PreferencesFile } from "../preferences";
import { makeStore, PNG_1x1, removeRoot, settle, temporaryRoot } from "./fixtures";

const roots: string[] = [];
const root = () => { const r = temporaryRoot(); roots.push(r); return r; };
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

const model = (name: string, effort: string, efforts: string[]): AgentModel => ({
  model: name, displayName: name.toUpperCase(), description: "", hidden: false, isDefault: false, defaultReasoningEffort: effort,
  supportedReasoningEfforts: efforts.map((e) => ({ reasoningEffort: e, description: "" })),
});

describe("AppStore workspace", () => {
  it("selects projects without losing drafts and persists the selection", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const first = makeThread({ title: "First", workingDirectory: directory });
    const pinned = makeThread({ title: "Pinned", workingDirectory: directory }); pinned.isPinned = true;
    const project = makeProject({ name: "Destination", rootPath: directory, threads: [first, pinned] }); project.isCollapsed = true;
    const empty = makeProject({ name: "Empty", rootPath: directory });
    store.replaceArchive(makeArchive({ projects: [empty, project], selectedProjectID: empty.id }));
    store.setDraftReady(first.id, true);
    await store.selectProject(project.id);
    expect(store.thread?.id).toBe(pinned.id);
    expect(store.project!.isCollapsed).toBe(false);
    await store.selectThread(first.id, project.id);
    await store.selectProject(project.id);
    expect(store.thread?.id).toBe(first.id);
    await store.saveNow();
    const saved = await storage.load();
    expect(saved.selectedProjectID).toBe(project.id);
    expect(saved.selectedThreadID).toBe(first.id);
    expect(saved.projects[1].isCollapsed).toBe(false);
    await store.selectProject(empty.id);
    expect(store.thread).toBeUndefined();
    expect(store.project?.threads.length).toBe(0);
    await store.selectProject(newID());
    expect(store.project?.id).toBe(empty.id);
    await store.shutdown();
  });

  it("reuses the draft thread and remembers provider choices across projects and relaunch", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const original = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "First", rootPath: directory, threads: [original] });
    const second = makeProject({ name: "Second", rootPath: join(directory, "second") });
    store.replaceArchive(makeArchive({ projects: [project, second], selectedProjectID: project.id, selectedThreadID: original.id }));
    store.state.update((d) => { d.modelCatalogs[`codex:${directory}`] = [model("test-model", "high", ["high"])]; });
    store.selectModel("test-model");
    store.selectPermissions("readOnly", original.id);
    const expected: AgentSettings = { model: "test-model", reasoningEffort: "high", permissionMode: "readOnly" };
    const snapshot = makeSnapshot({ projectID: project.id, workingDirectory: directory, path: "sample.swift", scope: "working", baseRevision: "base", lines: [{ id: 0, kind: "addition", text: "let a = 1", newLine: 1 }] });
    const document = ReviewDocument.fromSnapshot(snapshot);
    const attachment = document.attachment(document.attachmentRangeForLineAt(0, { location: 0, length: 0 })!)!;
    await store.attach(attachment);
    store.setDraftReady(original.id, true);
    for (let i = 0; i < 3; i++) await store.newThread();
    expect(store.project?.threads.length).toBe(1);
    expect(store.thread?.id).toBe(original.id);
    expect(store.draft(original.id).code).toEqual([attachment]);
    store.state.update((d) => { d.archive.projects[0].threads[0].messages = [makeMessage("user", "Started")]; });
    await store.newThread();
    expect(store.thread?.id).not.toBe(original.id);
    expect(store.thread?.agentSettings).toEqual(expected);
    await store.newThread({ projectID: second.id });
    expect(store.thread?.workingDirectory).toBe(second.rootPath);
    expect(store.thread?.agentSettings).toEqual(expected);
    await store.changeHarness("claude");
    expect(store.thread?.agentSettings).toEqual({});
    await store.changeHarness("codex");
    expect(store.thread?.agentSettings).toEqual(expected);
    await store.saveNow();
    await store.shutdown();
    const { store: reloaded } = await makeStore(directory);
    reloaded.state.update((d) => { d.archive.projects[1].threads[0].remoteSessionID = "existing-session"; });
    await reloaded.newThread();
    expect(reloaded.project?.threads.length).toBe(2);
    expect(reloaded.thread?.agentSettings).toEqual(expected);
    reloaded.selectPermissions("fullAccess", reloaded.thread!.id);
    reloaded.state.update((d) => { d.archive.projects[1].threads[1].messages = [makeMessage("user", "Started")]; });
    await reloaded.newThread();
    expect(reloaded.thread?.agentSettings.permissionMode).toBe("fullAccess");
    reloaded.selectPermissions("readOnly", reloaded.thread!.id);
    await reloaded.newThread({ projectID: project.id });
    expect(reloaded.thread?.agentSettings.permissionMode).toBe("readOnly");
    await reloaded.shutdown();
    void storage;
  });

  it("keeps permissions out of reach of running and wrong threads", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.selectPermissions("readOnly", thread.id);
    store.beginWork(thread.id);
    store.selectPermissions("fullAccess", thread.id);
    expect(store.thread?.agentSettings.permissionMode).toBe("readOnly");
    store.handle({ type: "interrupted" }, thread.id);
    store.selectPermissions("fullAccess", newID());
    expect(store.thread?.agentSettings.permissionMode).toBe("readOnly");
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].agentSettings.permissionMode).toBe("readOnly");
    await store.changeHarness("claude");
    store.selectPermissions("fullAccess", thread.id);
    expect(store.thread?.agentSettings.permissionMode).toBeUndefined();
    await store.shutdown();
  });

  it("keeps reasoning separate from answers and groups it without hiding errors", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.handle({ type: "reasoningDelta", text: "A" }, thread.id);
    store.handle({ type: "reasoningDelta", text: " summary" }, thread.id);
    store.handle({ type: "activity", text: "Command" }, thread.id);
    store.handle({ type: "textDelta", text: "Answer" }, thread.id);
    store.handle({ type: "failed", text: "Connection issue" }, thread.id);
    const groups = messageGroups(store.thread!.messages);
    expect(groups.length).toBe(3);
    expect(groups[0].isDetails).toBe(true);
    expect(groups[0].messages.map((m) => m.text)).toEqual(["A summary", "Command"]);
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].messages).toEqual(store.thread!.messages);
    await store.shutdown();
  });

  it("only updates the draft when attaching code", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    const snapshot = makeSnapshot({ projectID: project.id, workingDirectory: directory, path: "sample.swift", scope: "working", baseRevision: "base", lines: [{ id: 0, kind: "addition", text: "let value = 42", newLine: 7 }] });
    const document = ReviewDocument.fromSnapshot(snapshot);
    const attachment = document.attachment(document.attachmentRangeForLineAt(0, { location: 0, length: 0 })!)!;
    await store.attach(attachment);
    expect(store.draft(thread.id).code).toEqual([attachment]);
    expect(store.draft(thread.id).code[0].newLines).toEqual([7, 7]);
    expect(store.thread!.messages).toEqual([]);
    expect(store.s.running).toEqual([]);
    expect(store.canSend(thread.id, "")).toBe(false);
    await store.shutdown();
  });

  it("adds pasted screenshots to the draft only, for both providers", async () => {
    const directory = root();
    const { store, platform } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    platform.clipboard = undefined;
    expect(await store.pasteImage(thread.id)).toBe(false);
    platform.clipboard = PNG_1x1;
    expect(await store.pasteImage(thread.id)).toBe(true);
    expect(store.draft(thread.id).images.length).toBe(1);
    expect(store.canSend(thread.id, "")).toBe(true);
    expect(store.thread!.messages).toEqual([]);
    const captured = store.draft(thread.id).images[0].pngBase64;
    platform.clipboard = Buffer.from("invalid");
    expect(await store.pasteImage(thread.id)).toBe(true);
    expect(store.draft(thread.id).images.length).toBe(1);
    expect(store.draft(thread.id).images[0].pngBase64).toBe(captured);
    await store.changeHarness("claude");
    platform.clipboard = PNG_1x1;
    expect(await store.pasteImage(thread.id)).toBe(true);
    expect(store.draft(thread.id).images.length).toBe(2);
    await store.changeHarness("codex");
    for (let i = 0; i < 5; i++) await store.pasteImage(thread.id);
    expect(store.draft(thread.id).images.length).toBe(4);
    await store.newThread();
    expect(store.thread?.id).toBe(thread.id);
    expect(store.draft(thread.id).images.length).toBe(4);
    store.deleteThread(thread.id, project.id);
    expect(store.s.drafts[thread.id]).toBeUndefined();
    await store.shutdown();
  });

  it("persists the executable preference, invalidates catalogs and protects active turns", async () => {
    const directory = root();
    const executable = join(directory, "codex fixture");
    writeFileSync(executable, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    const { store } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.state.update((d) => { d.modelCatalogs[`codex:${directory}`] = []; d.modelErrors[`codex:${directory}`] = "old error"; });
    store.setCodexExecutable(executable);
    expect(store.codexExecutable).toBe(executable);
    expect(store.harnessDescriptors()[0].executable).toBe(executable);
    expect(store.s.modelCatalogs).toEqual({}); expect(store.s.modelErrors).toEqual({});
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(new PreferencesFile(directory).get("codexExecutablePath")).toBe(executable);
    store.beginWork(thread.id);
    store.setCodexExecutable(undefined);
    expect(store.s.codexExecutablePath).toBe(executable);
    store.handle({ type: "interrupted" }, thread.id);
    store.setCodexExecutable(directory);
    expect(store.s.codexExecutablePath).toBe(executable);
    rmSync(executable);
    expect(store.codexExecutable).toBeUndefined();
    expect(await store.send(thread.id, "Keep draft")).toBe(false);
    expect(store.s.running).toEqual([]);
    store.setCodexExecutable(undefined);
    expect(store.s.codexExecutablePath).toBeUndefined();
    await store.shutdown();
  });

  it("normalizes and persists model selection and respects a running turn", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.state.update((d) => { d.modelCatalogs[`codex:${directory}`] = [model("a", "medium", ["medium", "high"]), model("b", "low", ["low"])]; });
    store.selectModel("a"); store.selectReasoning("high");
    expect(store.thread?.agentSettings).toEqual({ model: "a", reasoningEffort: "high" });
    store.selectReasoning("unsupported");
    expect(store.thread?.agentSettings.reasoningEffort).toBe("high");
    store.beginWork(thread.id); store.selectModel("b"); await store.changeHarness("claude");
    expect(store.thread?.harness).toBe("codex");
    expect(store.thread?.agentSettings.model).toBe("a");
    store.handle({ type: "interrupted" }, thread.id); store.selectModel("b");
    expect(store.thread?.agentSettings).toEqual({ model: "b", reasoningEffort: "low" });
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].agentSettings).toEqual(store.thread?.agentSettings);
    store.state.update((d) => { d.modelCatalogs[`codex:${directory}`] = []; });
    expect(await store.send(thread.id, "Keep this draft")).toBe(false);
    expect(store.s.running).toEqual([]);
    await store.changeHarness("claude");
    expect(store.thread?.agentSettings).toEqual({});
    await store.shutdown();
  });

  it("protects running work from removal and cleans drafts", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Test", rootPath: directory, threads: [thread] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    store.state.update((d) => { d.drafts[thread.id] = { images: [], code: [], annotations: [] }; });
    store.beginWork(thread.id);
    store.deleteThread(thread.id, project.id);
    store.removeProject(project.id);
    expect(store.project?.threads.length).toBe(1);
    expect(store.s.drafts[thread.id]).toBeDefined();
    store.handle({ type: "interrupted" }, thread.id);
    store.deleteThread(thread.id, project.id);
    expect(store.s.drafts[thread.id]).toBeUndefined();
    expect(store.thread).toBeUndefined();
    store.removeProject(project.id);
    expect(store.archive.projects).toEqual([]);
    await store.shutdown();
  });

  it("records completion, failure, stop and quit without provider calls", async () => {
    const directory = root();
    const { store, storage } = await makeStore(directory);
    const first = makeThread({ workingDirectory: directory }); first.messages = [makeMessage("user", "One")];
    const second = makeThread({ workingDirectory: directory }); second.messages = [makeMessage("user", "Two")];
    const project = makeProject({ name: "Fixture", rootPath: directory, threads: [first, second] });
    store.replaceArchive(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: second.id }));
    store.beginWork(first.id); store.beginWork(second.id);
    store.handle({ type: "textDelta", text: "Response" }, first.id);
    store.handle({ type: "finished" }, first.id);
    const done = store.archive.projects[0].threads[0].messages;
    expect(done[0].work?.outcome).toBe("completed");
    expect(done[0].work?.elapsed).toBeDefined();
    expect(done[1].completedAt).toBeDefined();
    expect(store.thread!.messages[0].work?.outcome).toBeUndefined();
    store.stop(second.id);
    store.handle({ type: "finished" }, second.id);
    expect(store.thread!.messages[0].work?.outcome).toBe("stopped");
    store.handle({ type: "finished" }, first.id);
    expect(store.archive.projects[0].threads[0].messages).toEqual(done);
    store.state.update((d) => { d.archive.projects[0].threads[0].messages.push(makeMessage("user", "Again")); });
    store.beginWork(first.id);
    store.handle({ type: "failed", text: "Fixture error" }, first.id);
    expect(store.archive.projects[0].threads[0].messages[2].work?.outcome).toBe("failed");
    store.state.update((d) => { d.archive.projects[0].threads[1].messages.push(makeMessage("user", "Interrupted by quit")); });
    store.beginWork(second.id);
    await store.shutdown();
    expect(store.archive.projects[0].threads[1].messages.at(-1)?.work?.outcome).toBe("interrupted");
    expect((await storage.load()).projects[0].threads).toEqual(store.archive.projects[0].threads);
  });
});

describe("Projectless chats", () => {
  it("starts a fresh workspace in Chats and persists without a repository", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const chat = store.thread!, collection = chatsProject(store.archive)!;
    expect(collection.name).toBe("Chats");
    expect(collection.rootPath).toBe("");
    expect(orderedProjects(store.archive)).toEqual([]);
    expect(store.project?.id).toBe(collection.id);
    expect(existsSync(chat.workingDirectory)).toBe(true);
    expect(existsSync(join(chat.workingDirectory, ".git"))).toBe(false);
    expect(statSync(chat.workingDirectory).mode & 0o777).toBe(0o700);
    store.renameThread(chat.id, "Weekend ideas");
    store.toggleThreadPin(chat.id);
    store.beginWork(chat.id);
    store.receive({ type: "textDelta", text: "A saved idea 🐙" }, chat.id);
    store.receive({ type: "finished" }, chat.id);
    await store.shutdown();
    const { store: reload } = await makeStore(directory);
    expect(reload.archive.projects.filter((p) => p.isChatCollection).length).toBe(1);
    expect(reload.thread?.id).toBe(chat.id);
    expect(reload.thread?.workingDirectory).toBe(chat.workingDirectory);
    expect(reload.thread?.messages.at(-1)?.text).toBe("A saved idea 🐙");
    expect(reload.thread?.title).toBe("Weekend ideas");
    expect(reload.thread?.isPinned).toBe(true);
    expect(recentThreads(reload.archive)[0]?.thread.id).toBe(chat.id);
    await reload.shutdown();
  });

  it("preserves a selected project named Chats when migrating", async () => {
    const directory = root();
    const storage = new WorkspaceStore(join(directory, "data", "workspace.json"));
    const thread = makeThread({ workingDirectory: directory });
    const project = makeProject({ name: "Chats", rootPath: directory, threads: [thread] });
    await storage.save(makeArchive({ projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id }));
    const { store } = await makeStore(directory);
    expect(orderedProjects(store.archive).map((p) => p.id)).toEqual([project.id]);
    expect(store.thread?.id).toBe(thread.id);
    expect(chatsProject(store.archive)?.id).not.toBe(project.id);
    await store.newChat();
    expect(store.project?.isChatCollection).toBe(true);
    expect(searchableThreads(store.archive).map((e) => e.thread.id)).toEqual([store.thread!.id, thread.id]);
    await store.selectThread(thread.id, project.id);
    expect(store.thread?.id).toBe(thread.id);
    await store.shutdown();
  });

  it("reuses a draft chat but gives started chats their own directories", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const first = store.thread!;
    store.setDraftReady(first.id, true);
    await store.newChat();
    expect(store.thread?.id).toBe(first.id);
    store.state.update((d) => { d.archive.projects.find((p) => p.isChatCollection)!.threads[0].messages = [makeMessage("user", "Started")]; });
    await store.newChat();
    const second = store.thread!;
    expect(second.id).not.toBe(first.id);
    expect(second.workingDirectory).not.toBe(first.workingDirectory);
    expect(chatsProject(store.archive)?.threads.length).toBe(2);
    store.deleteThread(second.id, store.project!.id);
    expect(store.thread?.id).toBe(first.id);
    expect(existsSync(second.workingDirectory)).toBe(true);
    await store.shutdown();
  });

  it("cannot remove, rename or pin the built-in collection", async () => {
    const directory = root();
    const { store } = await makeStore(directory);
    const chats = chatsProject(store.archive)!;
    store.renameProject(chats.id, "Other");
    store.toggleProjectPin(chats.id);
    store.removeProject(chats.id);
    expect(chatsProject(store.archive)?.name).toBe("Chats");
    expect(chatsProject(store.archive)?.isPinned).toBe(false);
    store.deleteThread(store.thread!.id, chats.id);
    await store.openChats();
    expect(store.thread).toBeDefined();
    expect(chatsProject(store.archive)?.threads.length).toBe(1);
    await store.shutdown();
  });

  it("neither creates nor overwrites chats when the archive is unreadable", async () => {
    const directory = root();
    mkdirSync(join(directory, "data"), { mode: 0o700 });
    writeFileSync(join(directory, "data", "workspace.json"), "not an archive", { mode: 0o600 });
    const { store } = await makeStore(directory);
    await store.newChat(); await store.shutdown();
    expect(chatsProject(store.archive)).toBeUndefined();
    expect(readFileSync(join(directory, "data", "workspace.json"), "utf8")).toBe("not an archive");
    expect(existsSync(join(directory, "data", "ChatWorkspaces"))).toBe(false);
    expect(store.s.error).toContain("Could not load workspace");
  });

  it("rejects a symlinked or broadly permitted chat directory", async () => {
    const directory = root();
    const storage = new WorkspaceStore(join(directory, "workspace.json"));
    await storage.save(makeArchive());
    const outside = join(directory, "other");
    mkdirSync(outside);
    symlinkSync(outside, join(directory, "ChatWorkspaces"));
    await expect(storage.prepareChatDirectory(newID())).rejects.toThrow();
    rmSync(join(directory, "ChatWorkspaces"));
    mkdirSync(join(directory, "ChatWorkspaces"), { mode: 0o755 });
    await expect(storage.prepareChatDirectory(newID())).rejects.toThrow();
  });
});

void settle;
