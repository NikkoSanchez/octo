import { afterEach, describe, expect, it } from "vitest";
import { attachmentPromptContext, chatTurns, makeImage, makeSnapshot, SourceDocument, turnResponses } from "@octo/core";
import { makeInteraction as interaction } from "@octo/agents";
import { WorkspaceStore } from "@octo/core/node";
import { join } from "node:path";
import { makeStore, QueueHarness, removeRoot, settle, temporaryRoot } from "./fixtures";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

async function fixture() {
  const root = temporaryRoot(); roots.push(root);
  const harness = new QueueHarness();
  const { store } = await makeStore(root, { harness });
  return { store, harness, root };
}

describe("Message queue", () => {
  it("keeps FIFO order and attachments, and navigation does not reroute messages", async () => {
    const { store, harness } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First"); await settle();
    const image = makeImage(Buffer.from("image").toString("base64"), "fixture");
    const context = makeSnapshot({ projectID: store.project!.id, workingDirectory: store.thread!.workingDirectory, path: "file.swift", scope: "file", baseRevision: "fixture", lines: [] });
    const attachment = new SourceDocument("let value = 42\n", context).attachment({ location: 0, length: 14 })!;
    store.state.update((d) => { d.drafts[id] = { images: [image], code: [attachment], annotations: [] }; });
    await store.send(id, "Second");
    await store.send(id, "Third");
    expect(harness.sent).toEqual(["First"]);
    expect(store.s.queued[id].map((q) => q.message.text)).toEqual(["Second", "Third"]);
    expect(store.s.queued[id][0].message.images).toEqual([image]);
    await store.newChat();
    expect(store.thread?.id).not.toBe(id);
    harness.onEvent?.({ type: "finished" }); await settle();
    expect(harness.sent).toEqual(["First", "Second\n\nSelected code context (captured snapshots):\n" + attachmentPromptContext(attachment)]);
    expect(harness.sentImages.at(-1)).toEqual([image]);
    expect(store.thread?.messages.length).toBe(0);
    harness.onEvent?.({ type: "finished" }); await settle();
    expect(harness.sent.at(-1)).toBe("Third"); expect(harness.sent.length).toBe(3);
    harness.onEvent?.({ type: "finished" }); await settle();
    expect(store.isRunning(id)).toBe(false);
    await store.shutdown();
  });

  it("steers while a question waits, preserving work and archiving only after acceptance", async () => {
    const { store, harness, root } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First"); await settle();
    harness.onEvent?.({ type: "interaction", interaction: interaction({ title: "Choose direction", detail: "Fixture", fields: [], canDecline: true, cancellationDetail: "Cancel" }) });
    await store.send(id, "Focus on this");
    const queued = store.s.queued[id][0];
    const steer = store.steerQueued(queued.id, id); await settle();
    void store.steerQueued(queued.id, id);
    store.removeQueued(queued.id, id);
    expect(harness.steered).toEqual(["Focus on this"]);
    expect(store.thread!.messages.filter((m) => m.role === "user").length).toBe(1);
    expect(store.s.interactions[id].length).toBe(1);
    harness.steering?.resolve(); harness.steering = undefined; await steer; await settle();
    expect(store.thread!.messages.at(-1)?.isSteering).toBe(true);
    expect(store.s.interactions[id].length).toBe(1);
    expect(chatTurns(store.thread!.messages).length).toBe(1);
    harness.onEvent?.({ type: "message", text: "Answer" }); harness.onEvent?.({ type: "finished" }); await settle();
    expect(store.thread!.messages[0].work?.outcome).toBe("completed");
    expect(store.thread!.messages.find((m) => m.isSteering)?.work).toBeUndefined();
    expect(turnResponses(chatTurns(store.thread!.messages)[0]).map((m) => m.text)).toEqual(["Focus on this", "Answer"]);
    await store.saveNow();
    const reloaded = await new WorkspaceStore(join(root, "data", "workspace.json")).load();
    expect(reloaded.projects.find((p) => p.isChatCollection)?.threads[0].messages.find((m) => m.isSteering)?.text).toBe("Focus on this");
    await store.shutdown();
  });

  it("does not send a message twice when completion arrives before the steer acknowledgement", async () => {
    const { store, harness } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First"); await settle();
    await store.send(id, "Steer");
    const steer = store.steerQueued(store.s.queued[id][0].id, id); await settle();
    await store.send(id, "Next");
    harness.onEvent?.({ type: "message", text: "Final" }); harness.onEvent?.({ type: "finished" }); await settle();
    expect(harness.sent).toEqual(["First"]);
    harness.steering?.resolve(); harness.steering = undefined; await steer; await settle();
    expect(harness.sent).toEqual(["First", "Next"]);
    expect(store.thread!.messages.map((m) => m.text)).toEqual(["First", "Steer", "Final", "Next"]);
    expect(store.thread!.messages[0].work?.outcome).toBe("completed");
    await store.shutdown();
  });

  it("pauses the queue on a rejected steer or stop without dropping input", async () => {
    const { store, harness } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First"); await settle();
    await store.send(id, "Retain me");
    const queued = store.s.queued[id][0];
    const steer = store.steerQueued(queued.id, id); await settle();
    harness.steering?.reject(new Error("Turn mismatch")); harness.steering = undefined; await steer; await settle();
    expect(store.s.queueErrors[queued.id]).toBeDefined();
    expect(store.s.queued[id][0].message.text).toBe("Retain me");
    store.stop(id); await settle();
    expect(harness.sent).toEqual(["First"]);
    expect(store.thread!.messages[0].work?.outcome).toBe("stopped");
    store.selectPermissions("readOnly", id);
    store.resumeQueue(id); await settle();
    expect(harness.sent).toEqual(["First", "Retain me"]);
    expect(harness.sentSettings.at(-1)?.permissionMode).toBe("readOnly");
    await store.send(id, "After failure");
    harness.onEvent?.({ type: "failed", text: "Disconnected" }); await settle();
    expect(store.s.queued[id].length).toBe(1);
    expect(store.s.pausedQueues).toContain(id);
    store.removeQueued(store.s.queued[id][0].id, id);
    expect(store.s.queued[id].length).toBe(0);
    await store.shutdown();
  });

  it("never leaves tool activity running after a missing completion or a late start", async () => {
    const { store, harness } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First"); await settle();
    harness.onEvent?.({ type: "toolActivity", tool: { id: "call", server: "cua_repl", tool: "js", state: "running", detail: "" } });
    harness.onEvent?.({ type: "finished" }); await settle();
    expect(store.thread!.messages.at(-1)?.toolActivity?.state).toBe("interrupted");
    harness.onEvent?.({ type: "toolActivity", tool: { id: "late", server: "cua_repl", tool: "js", state: "running", detail: "" } });
    expect(store.thread!.messages.length).toBe(2);
    expect(store.canSteer(id)).toBe(false);
    await store.shutdown();
  });

  it("never drains the queue after a stop during startup or a provider interruption", async () => {
    const { store, harness } = await fixture();
    const id = store.thread!.id;
    await store.send(id, "First");
    await store.send(id, "Queued"); store.stop(id); await settle();
    expect(harness.sent).toEqual([]);
    expect(store.isRunning(id)).toBe(false);
    expect(store.s.queued[id].length).toBe(1);
    store.resumeQueue(id); await settle();
    await store.send(id, "Still queued");
    harness.onEvent?.({ type: "interrupted" }); await settle();
    expect(harness.sent).toEqual(["Queued"]);
    expect(store.thread!.messages.at(-1)?.work?.outcome).toBe("interrupted");
    await store.shutdown();
  });
});
