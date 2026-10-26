import { describe, expect, it } from "vitest";
import {
  createSplitLayout, equalizeSplits, focusTarget, insertSplit, removeSplit, resizeSplit, setSplitRatio, setZoomed, splitDividers,
  splitFrames, splitLeaves, SPLIT_MINIMUM_RATIO, type SplitDirection, type SplitLayout,
} from "../src";

/** a | b, with b split into b over c. */
function threePanes(): SplitLayout {
  const layout = createSplitLayout("a");
  expect(insertSplit(layout, "b", "a", "right")).toBe(true);
  expect(insertSplit(layout, "c", "b", "down")).toBe(true);
  return layout;
}

describe("SplitLayout", () => {
  it("places a new pane on the requested side", () => {
    for (const [direction, expected] of [["right", ["a", "b"]], ["down", ["a", "b"]], ["left", ["b", "a"]], ["up", ["b", "a"]]] as [SplitDirection, string[]][]) {
      const layout = createSplitLayout("a");
      insertSplit(layout, "b", "a", direction);
      expect(splitLeaves(layout)).toEqual(expected);
      if (layout.root.type !== "split") throw new Error("not split");
      expect(layout.root.axis).toBe(direction === "left" || direction === "right" ? "horizontal" : "vertical");
      expect(layout.root.ratio).toBe(0.5);
    }
    const layout = createSplitLayout("a");
    expect(insertSplit(layout, "a", "a", "right")).toBe(false);
    expect(insertSplit(layout, "b", "missing", "right")).toBe(false);
  });

  it("collapses the parent into the sibling on removal and keeps the last pane", () => {
    const layout = threePanes();
    expect(removeSplit(layout, "b")).toBe(true);
    expect(layout.root).toEqual({ type: "split", axis: "horizontal", ratio: 0.5, first: { type: "leaf", leaf: "a" }, second: { type: "leaf", leaf: "c" } });
    expect(removeSplit(layout, "a")).toBe(true);
    expect(layout.root).toEqual({ type: "leaf", leaf: "c" });
    expect(removeSplit(layout, "c")).toBe(false);
    expect(removeSplit(layout, "missing")).toBe(false);
  });

  it("clears zoom when its pane leaves or the tree changes", () => {
    const layout = threePanes();
    setZoomed(layout, "missing");
    expect(layout.zoomed).toBeNull();
    setZoomed(layout, "c");
    removeSplit(layout, "c");
    expect(layout.zoomed).toBeNull();
    setZoomed(layout, "a");
    insertSplit(layout, "d", "b", "right");
    expect(layout.zoomed).toBeNull();
  });

  it("wraps previous and next in tree order", () => {
    const layout = threePanes();
    expect(focusTarget(layout, "next", "a")).toBe("b");
    expect(focusTarget(layout, "next", "c")).toBe("a");
    expect(focusTarget(layout, "previous", "a")).toBe("c");
    expect(focusTarget(createSplitLayout("a"), "next", "a")).toBeUndefined();
  });

  it("finds the nearest pane in a direction", () => {
    const layout = threePanes();
    expect(focusTarget(layout, "right", "a")).toBe("b");
    expect(focusTarget(layout, "left", "c")).toBe("a");
    expect(focusTarget(layout, "down", "b")).toBe("c");
    expect(focusTarget(layout, "up", "c")).toBe("b");
    expect(focusTarget(layout, "left", "a")).toBeUndefined();
    expect(focusTarget(layout, "up", "b")).toBeUndefined();
    expect(focusTarget(layout, "down", "a")).toBeUndefined();
  });

  it("ignores ratios for spatial focus, like Ghostty", () => {
    const layout = threePanes();
    setSplitRatio(layout, 0.9, [1]);
    expect(focusTarget(layout, "down", "b")).toBe("c");
    expect(focusTarget(layout, "right", "a")).toBe("b");
  });

  it("leaves the gap for dividers and covers the bounds", () => {
    const layout = threePanes();
    const bounds = { x: 0, y: 0, width: 801, height: 401 };
    const frames = splitFrames(layout, bounds, 1);
    expect(frames.get("a")).toEqual({ x: 0, y: 0, width: 400, height: 401 });
    expect(frames.get("b")).toEqual({ x: 401, y: 0, width: 400, height: 200 });
    expect(frames.get("c")).toEqual({ x: 401, y: 201, width: 400, height: 200 });
    const dividers = splitDividers(layout, bounds, 1);
    expect(dividers.map((d) => d.path)).toEqual([[], [1]]);
    expect(dividers[0].frame).toEqual({ x: 400, y: 0, width: 1, height: 401 });
    expect(dividers[1].frame).toEqual({ x: 401, y: 200, width: 400, height: 1 });
    expect(dividers[1].container).toEqual({ x: 401, y: 0, width: 400, height: 401 });
  });

  it("moves the nearest divider on the matching axis", () => {
    const layout = threePanes();
    const bounds = { x: 0, y: 0, width: 800, height: 400 };
    expect(resizeSplit(layout, "c", "up", 40, bounds)).toBe(true);
    expect(splitDividers(layout, bounds)[1].ratio).toBeCloseTo(0.4, 9);
    expect(resizeSplit(layout, "c", "right", 80, bounds)).toBe(true);
    expect(splitDividers(layout, bounds)[0].ratio).toBeCloseTo(0.6, 9);
    expect(resizeSplit(layout, "a", "down", 10, bounds)).toBe(false);
    expect(resizeSplit(layout, "a", "left", 10_000, bounds)).toBe(true);
    expect(splitDividers(layout, bounds)[0].ratio).toBe(SPLIT_MINIMUM_RATIO);
  });

  it("weighs panes along each axis when equalizing", () => {
    const layout = threePanes();
    insertSplit(layout, "d", "c", "right");
    setSplitRatio(layout, 0.8, []);
    equalizeSplits(layout);
    if (layout.root.type !== "split" || layout.root.second.type !== "split") throw new Error("shape");
    expect(layout.root.ratio).toBe(0.5);
    expect(layout.root.second.ratio).toBe(0.5);
    const row = createSplitLayout("a");
    insertSplit(row, "b", "a", "right");
    insertSplit(row, "c", "b", "right");
    equalizeSplits(row);
    if (row.root.type !== "split") throw new Error("shape");
    expect(row.root.ratio).toBeCloseTo(1 / 3, 9);
  });
});
