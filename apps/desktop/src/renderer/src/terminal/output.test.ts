import { expect, it } from "vitest";
import { nextOutput } from "./output";
it("drops replayed output and slices snapshot/event overlap at UTF-16 offsets", () => {
  expect(nextOutput(4, { cursor: 4, data: "a🐙b" })).toEqual({ cursor: 4, data: "" });
  expect(nextOutput(4, { cursor: 6, data: "a🐙bcd" })).toEqual({ cursor: 6, data: "cd" });
  expect(nextOutput(0, { cursor: 3, data: "🐙a" })).toEqual({ cursor: 3, data: "🐙a" });
});
it("requires a fresh snapshot when output has a gap", () => {
  expect(nextOutput(3, { cursor: 10, data: "next" })).toBeUndefined();
});
