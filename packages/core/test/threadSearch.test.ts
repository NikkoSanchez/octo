import { describe, expect, it } from "vitest";
import {
  makeArchive, makeMessage, makeProject, makeThread, searchableThreads, ThreadFind, ThreadPreview, ThreadSearch, type ChatMessage,
} from "../src";

describe("ThreadFind", () => {
  it("matches shown messages ignoring case and accents", () => {
    const messages: ChatMessage[] = [
      makeMessage("user", "Please fix the Café menu"),
      makeMessage("activity", "rg cafe Sources/"),
      makeMessage("reasoning", "The cafe view is broken"),
      makeMessage("assistant", "Fixed the **cafe** layout."),
      makeMessage("error", "CAFÉ failed to build"),
    ];
    expect(ThreadFind.matches("cafe", messages)).toEqual([messages[0].id, messages[3].id, messages[4].id]);
    expect(ThreadFind.matches("  ", messages)).toEqual([]);
    expect(ThreadFind.matches(" menu ", messages)).toEqual([messages[0].id]);
  });

  it("finds every occurrence", () => {
    const text = "Go to 👋🏽 go GO, gopher";
    expect(ThreadFind.ranges("go", text).map(([s, e]) => text.slice(s, e))).toEqual(["Go", "go", "GO", "go"]);
    expect(ThreadFind.ranges("aa", "aaaa").length).toBe(2);
    expect(ThreadFind.ranges("", text)).toEqual([]);
  });
});

describe("ThreadPreview", () => {
  it("reduces Markdown to one readable line", () => {
    const markdown = "## Found it\n\n> `SidebarObservation` republished on **every** store tick.\n\n```swift\nlet hidden = true\n```\n- Coalesced to [one diff](https://example.com) per run loop\n2. Idle CPU is *back* to 0%.";
    expect(ThreadPreview.plain(markdown)).toBe("Found it SidebarObservation republished on every store tick. Coalesced to one diff per run loop Idle CPU is back to 0%.");
    expect(ThreadPreview.plain("```\nonly code\n```")).toBe("");
    expect(ThreadPreview.plain("3 files changed")).toBe("3 files changed");
  });

  it("truncates long replies and reads only their head", () => {
    const preview = ThreadPreview.plain("word ".repeat(2_000));
    expect(Array.from(preview).length).toBe(160);
    expect(preview.endsWith("…")).toBe(true);
  });

  it("uses the newest reply or the user's unanswered message", () => {
    const thread = makeThread({ title: "Fixture", workingDirectory: "/tmp" });
    expect(ThreadPreview.text(thread)).toBeUndefined();
    thread.messages = [makeMessage("user", "Can tabs survive a relaunch?")];
    expect(ThreadPreview.text(thread)).toBe("You: Can tabs survive a relaunch?");
    thread.messages.push(makeMessage("assistant", "Done. **Tabs** persist per project."));
    thread.messages.push(makeMessage("activity", "Edited 4 files"));
    expect(ThreadPreview.text(thread)).toBe("Done. Tabs persist per project.");
  });
});

describe("ThreadSearch", () => {
  function archive() {
    const titled = makeThread({ title: "Fix runaway sidebar layout", workingDirectory: "/tmp" });
    titled.lastActivityAt = 100_000;
    const older = makeThread({ title: "Panel tabs", workingDirectory: "/tmp" });
    older.lastActivityAt = 200_000;
    older.messages = [makeMessage("user", "Why does the sidebar hang?"), makeMessage("activity", "sidebar tool output"),
      makeMessage("assistant", "Context words here. ".repeat(5) + "The SIDEBAR observation republished on every tick, so it re-rendered constantly.")];
    const newer = makeThread({ title: "Ghostty paste", workingDirectory: "/tmp" });
    newer.lastActivityAt = 300_000;
    newer.messages = [makeMessage("assistant", "Bracketed paste works in the sidebar terminal.")];
    for (const thread of [titled, older, newer]) {
      thread.createdAt = 0;
      for (const message of thread.messages) message.createdAt = 0;
    }
    const octo = makeProject({ name: "octo", rootPath: "/tmp/octo", threads: [titled, older] });
    const other = makeProject({ name: "pfl-caller", rootPath: "/tmp/pfl", threads: [newer] });
    return { archive: makeArchive({ projects: [octo, other] }), titled, older, newer };
  }

  it("ranks title matches first, then the most recent", () => {
    const { archive: a, titled, older, newer } = archive();
    const results = ThreadSearch.results("sidebar", searchableThreads(a));
    expect(results.map((r) => r.threadID)).toEqual([titled.id, newer.id, older.id]);
    expect(results[0].snippet).toBeUndefined();
    expect(results[1].snippet).toBe("Bracketed paste works in the sidebar terminal.");
  });

  it("matches the query as a phrase within one field", () => {
    const { archive: a, titled, older, newer } = archive();
    const threads = searchableThreads(a);
    expect(ThreadSearch.results("runaway SIDEBAR", threads).map((r) => r.threadID)).toEqual([titled.id]);
    expect(ThreadSearch.results("the  sidebar hang", threads).map((r) => r.threadID)).toEqual([older.id]);
    expect(ThreadSearch.results("pfl-caller", threads).map((r) => r.threadID)).toEqual([newer.id]);
    expect(ThreadSearch.results("sidebar runaway", threads)).toEqual([]);
    expect(ThreadSearch.results("panel republished", threads)).toEqual([]);
    expect(ThreadSearch.results("   ", threads)).toEqual([]);
    expect(ThreadSearch.results("tool output", threads)).toEqual([]);
  });

  it("does not match common words scattered through a message", () => {
    const thread = makeThread({ title: "Unrelated", workingDirectory: "/tmp" });
    thread.messages = [makeMessage("user", "This change is a big one; please test it."),
      makeMessage("assistant", "Wrapped reply: this is\na test of wrapping.")];
    const threads = searchableThreads(makeArchive({ projects: [makeProject({ name: "octo", rootPath: "/tmp/octo", threads: [thread] })] }));
    const results = ThreadSearch.results("This is a test", threads);
    expect(results.map((r) => r.threadID)).toEqual([thread.id]);
    expect(results[0].snippet).toBe("Wrapped reply: this is a test of wrapping.");
    expect(ThreadSearch.results("this is a big", threads)).toEqual([]);
  });

  it("shows the newest match in context", () => {
    const { archive: a, older } = archive();
    const result = ThreadSearch.results("sidebar observation", searchableThreads(a))[0];
    expect(result.threadID).toBe(older.id);
    expect(result.snippet?.startsWith("…")).toBe(true);
    expect(result.snippet?.includes("SIDEBAR observation republished")).toBe(true);
    expect(result.snippet?.includes("\n")).toBe(false);
  });
});
