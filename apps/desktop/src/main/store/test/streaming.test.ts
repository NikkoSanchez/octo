import { afterEach, describe, expect, it } from "vitest";
import { makeArchive, makeMessage, makeProject, makeThread, toolActivityText } from "@octo/core";
import { makeStore, removeRoot, temporaryRoot } from "./fixtures";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

async function fixture() {
  const root = temporaryRoot(); roots.push(root);
  const { store, storage } = await makeStore(root);
  const a = makeThread({ workingDirectory: root }), b = makeThread({ workingDirectory: root });
  a.messages = [makeMessage("user", "One")]; b.messages = [makeMessage("user", "Two")];
  store.replaceArchive(makeArchive({ projects: [makeProject({ name: "Concurrent", rootPath: root, threads: [a, b] })] }));
  store.beginWork(a.id); store.beginWork(b.id);
  return { store, storage, a: a.id, b: b.id };
}
const threads = (store: Awaited<ReturnType<typeof fixture>>["store"]) => store.archive.projects[0].threads;

describe("Streaming", () => {
  it("publishes concurrent fragments once without losing text", async () => {
    const { store, a, b } = await fixture();
    store.state.flush();
    let publications = 0;
    const unsubscribe = store.state.subscribe(() => publications++);
    for (let i = 0; i < 1_000; i++) { store.receive({ type: "textDelta", text: "🐙" }, a); store.receive({ type: "textDelta", text: "b" }, b); }
    store.state.flush();
    expect(publications).toBe(0);
    store.flushStreamText(); store.state.flush();
    expect(publications).toBe(1);
    expect(threads(store)[0].messages.at(-1)?.text).toBe("🐙".repeat(1_000));
    expect(threads(store)[1].messages.at(-1)?.text).toBe("b".repeat(1_000));
    unsubscribe();
    await store.shutdown();
  });

  it("keeps roles, tool activity and completion in order at boundaries", async () => {
    const { store, a } = await fixture();
    store.receive({ type: "reasoningDelta", text: "Thinking" }, a);
    store.receive({ type: "textDelta", text: "Answer" }, a);
    const tool = { id: "tool", server: "fixture", tool: "test", state: "running" as const, detail: "" };
    store.receive({ type: "toolActivity", tool }, a);
    store.receive({ type: "activityDelta", text: "Commentary" }, a);
    store.receive({ type: "textDelta", text: "Final" }, a);
    store.receive({ type: "finished" }, a);
    const messages = threads(store)[0].messages;
    const interrupted = { ...tool, state: "interrupted" as const };
    expect(messages.map((m) => m.text)).toEqual(["One", "Thinking", "Answer", toolActivityText(interrupted), "Commentary", "Final"]);
    expect(messages[3].toolActivity).toEqual(interrupted);
    expect(messages[4].toolActivity).toBeUndefined();
    expect(messages.at(-1)?.completedAt).toBeDefined();
    expect(messages[0].work?.outcome).toBe("completed");
    store.receive({ type: "textDelta", text: "Late" }, a);
    store.flushStreamText();
    expect(threads(store)[0].messages.at(-1)?.text).toBe("Final");
    await store.shutdown();
  });

  it("persists pending text on stop, failure and shutdown", async () => {
    const { store, storage, a, b } = await fixture();
    store.receive({ type: "textDelta", text: "Before stop" }, a);
    store.stop(a);
    store.receive({ type: "textDelta", text: "After stop" }, a);
    store.receive({ type: "finished" }, a);
    store.receive({ type: "textDelta", text: "Before error" }, b);
    store.receive({ type: "failed", text: "Disconnected" }, b);
    store.beginWork(b);
    store.receive({ type: "textDelta", text: "Before shutdown" }, b);
    await store.shutdown();
    const saved = (await storage.load()).projects[0].threads;
    expect(saved[0].messages.at(-1)?.text).toBe("Before stop");
    expect(saved[0].messages[0].work?.outcome).toBe("stopped");
    expect(saved[1].messages.map((m) => m.text)).toEqual(["Two", "Before error", "Disconnected", "Before shutdown"]);
  });

  it("flushes on the timer and the buffer limit without a protocol boundary", async () => {
    const { store, storage, a, b } = await fixture();
    store.receive({ type: "textDelta", text: "Timer" }, a);
    await new Promise((resolve) => setTimeout(resolve, 250));
    expect(threads(store)[0].messages.at(-1)?.text).toBe("Timer");
    const large = "x".repeat(65_536);
    store.receive({ type: "textDelta", text: large }, b);
    expect(threads(store)[1].messages.at(-1)?.text).toBe(large);
    store.receive({ type: "textDelta", text: " saved" }, a);
    await store.saveNow();
    expect((await storage.load()).projects[0].threads[0].messages.at(-1)?.text).toBe("Timer saved");
    await store.shutdown();
  });
});
