import { expect, it } from "vitest";
import { makeArchive, makeMessage, makeProject, makeThread } from "@octo/core";
import type { AppState } from "../../../shared/state";
import { selectedPlace, sidebarPresentation, sidebarTimestamp, threadWindow } from "./sidebar";
import { deepEqual } from "./equality";
import { insertCommand, slashToken } from "./slashCommands";

it("keeps the selected and running threads listed beyond the page limit", () => {
  const threads = Array.from({ length: 12 }, (_, i) => ({ id: String(i), running: i === 10 }));
  const window = threadWindow(threads, 5, "8");
  expect(window.threads.map((t) => t.id)).toEqual(["0", "1", "2", "3", "4", "8", "10"]);
  expect(window.hidden).toBe(5);
  expect(threadWindow(threads.slice(0, 4), 5).hidden).toBe(0);
});

it("does not change the sidebar presentation for streamed reply text", () => {
  const thread = makeThread({ workingDirectory: "/fixture" });
  thread.messages.push(makeMessage("assistant", "One"));
  const project = makeProject({ name: "Fixture", rootPath: "/fixture", threads: [thread] });
  const state = { archive: makeArchive({ projects: [project] }), running: [thread.id] } as AppState;
  const before = sidebarPresentation(state, {}, false, {});
  thread.messages[0].text = "More streamed output";
  expect(deepEqual(sidebarPresentation(state, {}, false, {}), before)).toBe(true);
  state.running = [];
  expect(deepEqual(sidebarPresentation(state, {}, false, {}), before)).toBe(false);
});

it("draws the selection where the thread was opened while it is listed there, else home, Recent, pinned", () => {
  expect(selectedPlace("recent", () => true)).toBe("recent");
  expect(selectedPlace("pinned", (place) => place !== "pinned")).toBe("home");
  expect(selectedPlace(undefined, (place) => place === "pinned")).toBe("pinned");
  expect(selectedPlace(undefined, () => false)).toBeUndefined();
});

it("formats row timestamps as Messages does", () => {
  const now = new Date(2026, 9, 25, 15, 0).getTime();
  expect(sidebarTimestamp(new Date(2026, 9, 24, 9, 0).getTime(), now)).toBe("Yesterday");
  expect(sidebarTimestamp(new Date(2026, 9, 21, 9, 0).getTime(), now)).toBe(new Date(2026, 9, 21).toLocaleDateString(undefined, { weekday: "long" }));
  expect(sidebarTimestamp(new Date(2026, 8, 1).getTime(), now)).toBe(new Date(2026, 8, 1).toLocaleDateString(undefined, { year: "2-digit", month: "numeric", day: "numeric" }));
});

it("replaces the complete slash token at UTF-16 caret offsets without sending", () => {
  const text = "🐙 /rev after", token = slashToken(text, 7)!;
  const command = { name: "review", description: "", argumentHint: "" };
  expect(insertCommand(text, token, command)).toEqual({ text: "🐙 /review after", caret: 11 });
  expect(slashToken("https://example.org", 18)).toBeUndefined();
  expect(slashToken("/folder/file", 8)).toBeUndefined();
});
