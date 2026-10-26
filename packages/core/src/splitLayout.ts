/** Where a new pane goes relative to the pane it splits, as in Ghostty's `new_split`. */
export type SplitDirection = "right" | "down" | "left" | "up";
/** A focus move between panes, as in Ghostty's `goto_split`. */
export type SplitFocusTarget = "previous" | "next" | "left" | "right" | "up" | "down";
/** `horizontal` places children side by side; `vertical` stacks them. */
export type SplitAxis = "horizontal" | "vertical";

export type SplitNode =
  | { type: "leaf"; leaf: string }
  /** `ratio` is the share of `first` (the left or top child). */
  | { type: "split"; axis: SplitAxis; ratio: number; first: SplitNode; second: SplitNode };

export interface Rect { x: number; y: number; width: number; height: number }

/** A divider between two children of the split at `path` (0 = first, 1 = second at each level). */
export interface SplitDivider {
  path: number[];
  axis: SplitAxis;
  ratio: number;
  /** The gap between the two children. */
  frame: Rect;
  /** The split's whole frame; a drag's position along `axis` maps into it. */
  container: Rect;
}

/**
 * A pane tree after Ghostty's macOS `SplitTree`: the same insertion, removal, spatial focus,
 * resize and equalize rules, so bindings behave as they do in Ghostty itself. Plain data, so it
 * crosses IPC and persists; functions edit it in place.
 */
export interface SplitLayout {
  root: SplitNode;
  /** One pane shown over the whole area; the others stay mounted behind it. */
  zoomed: string | null;
}

export const SPLIT_MINIMUM_RATIO = 0.1;

export function createSplitLayout(leaf: string): SplitLayout {
  return { root: { type: "leaf", leaf }, zoomed: null };
}

export function nodeLeaves(node: SplitNode): string[] {
  return node.type === "leaf" ? [node.leaf] : [...nodeLeaves(node.first), ...nodeLeaves(node.second)];
}

export const splitLeaves = (layout: SplitLayout) => nodeLeaves(layout.root);
export const isSplit = (layout: SplitLayout) => layout.root.type === "split";
export const splitContains = (layout: SplitLayout, leaf: string) => pathTo(layout, leaf) !== undefined;

/** Sets the zoomed pane; a pane not in the tree clears zoom. */
export function setZoomed(layout: SplitLayout, leaf: string | null): void {
  layout.zoomed = leaf !== null && splitContains(layout, leaf) ? leaf : null;
}

export function pathTo(layout: SplitLayout, leaf: string): number[] | undefined {
  const search = (node: SplitNode, path: number[]): number[] | undefined => {
    if (node.type === "leaf") return node.leaf === leaf ? path : undefined;
    return search(node.first, [...path, 0]) ?? search(node.second, [...path, 1]);
  };
  return search(layout.root, []);
}

export function nodeAt(layout: SplitLayout, path: number[]): SplitNode | undefined {
  let node: SplitNode = layout.root;
  for (const side of path) {
    if (node.type !== "split") return undefined;
    node = side === 0 ? node.first : node.second;
  }
  return node;
}

function replacing(node: SplitNode, path: number[], replacement: SplitNode): SplitNode {
  if (path.length === 0) return replacement;
  if (node.type !== "split") return node;
  const [side, ...rest] = path;
  return side === 0
    ? { ...node, first: replacing(node.first, rest, replacement) }
    : { ...node, second: replacing(node.second, rest, replacement) };
}

/** Splits `target` in half and places `leaf` in `direction`. Clears any zoom. */
export function insertSplit(layout: SplitLayout, leaf: string, target: string, direction: SplitDirection): boolean {
  const path = pathTo(layout, target);
  if (splitContains(layout, leaf) || !path) return false;
  const added: SplitNode = { type: "leaf", leaf }, old: SplitNode = { type: "leaf", leaf: target };
  const axis: SplitAxis = direction === "left" || direction === "right" ? "horizontal" : "vertical";
  const newFirst = direction === "left" || direction === "up";
  layout.root = replacing(layout.root, path, { type: "split", axis, ratio: 0.5, first: newFirst ? added : old, second: newFirst ? old : added });
  layout.zoomed = null;
  return true;
}

/** Removes a pane; its sibling takes the parent's place. The last pane cannot be removed. */
export function removeSplit(layout: SplitLayout, leaf: string): boolean {
  const path = pathTo(layout, leaf);
  if (!path || path.length === 0) return false;
  const side = path[path.length - 1];
  const parentPath = path.slice(0, -1);
  const parent = nodeAt(layout, parentPath);
  if (parent?.type !== "split") return false;
  layout.root = replacing(layout.root, parentPath, side === 0 ? parent.second : parent.first);
  if (layout.zoomed === leaf) layout.zoomed = null;
  return true;
}

type Visit = (node: SplitNode, frame: Rect, path: number[]) => void;

/** Pixel layouts round to whole points; the focus grid must not, or neighbouring edges drift apart. */
function divide(frame: Rect, axis: SplitAxis, ratio: number, gap: number, rounded: boolean): [Rect, Rect] {
  if (axis === "horizontal") {
    const available = Math.max(0, frame.width - gap);
    const width = rounded ? Math.round(available * ratio) : available * ratio;
    return [{ x: frame.x, y: frame.y, width, height: frame.height },
            { x: frame.x + width + gap, y: frame.y, width: available - width, height: frame.height }];
  }
  const available = Math.max(0, frame.height - gap);
  const height = rounded ? Math.round(available * ratio) : available * ratio;
  return [{ x: frame.x, y: frame.y, width: frame.width, height },
          { x: frame.x, y: frame.y + height + gap, width: frame.width, height: available - height }];
}

function walk(node: SplitNode, frame: Rect, gap: number, rounded: boolean, path: number[], visit: Visit): void {
  visit(node, frame, path);
  if (node.type !== "split") return;
  const [a, b] = divide(frame, node.axis, node.ratio, gap, rounded);
  walk(node.first, a, gap, rounded, [...path, 0], visit);
  walk(node.second, b, gap, rounded, [...path, 1], visit);
}

/** Columns and rows needed when each pane is one cell. */
function dimensions(node: SplitNode): { width: number; height: number } {
  if (node.type === "leaf") return { width: 1, height: 1 };
  const a = dimensions(node.first), b = dimensions(node.second);
  return node.axis === "horizontal"
    ? { width: a.width + b.width, height: Math.max(a.height, b.height) }
    : { width: Math.max(a.width, b.width), height: a.height + b.height };
}

export function focusTarget(layout: SplitLayout, target: SplitFocusTarget, from: string): string | undefined {
  const all = splitLeaves(layout);
  const index = all.indexOf(from);
  if (index === -1) return undefined;
  if (target === "previous") return all.length > 1 ? all[(index - 1 + all.length) % all.length] : undefined;
  if (target === "next") return all.length > 1 ? all[(index + 1) % all.length] : undefined;
  // Ghostty compares a grid where each pane counts as one cell, not the pixel layout.
  const frames = new Map<string, Rect>();
  const size = dimensions(layout.root);
  walk(layout.root, { x: 0, y: 0, ...size }, 0, false, [], (node, frame) => {
    if (node.type === "leaf") frames.set(node.leaf, frame);
  });
  const origin = frames.get(from)!;
  const epsilon = 1e-9;
  const maxX = (r: Rect) => r.x + r.width, maxY = (r: Rect) => r.y + r.height;
  const candidates = [...frames].filter(([leaf, frame]) => {
    if (leaf === from) return false;
    switch (target) {
      case "left": return maxX(frame) <= origin.x + epsilon;
      case "right": return frame.x >= maxX(origin) - epsilon;
      case "up": return maxY(frame) <= origin.y + epsilon;
      case "down": return frame.y >= maxY(origin) - epsilon;
    }
  });
  // Nearest by top-left corner; ties fall back to tree order so the result is stable.
  const distance = (r: Rect) => Math.hypot(r.x - origin.x, r.y - origin.y);
  let best: [string, Rect] | undefined;
  for (const candidate of candidates) {
    if (!best) { best = candidate; continue; }
    const da = distance(candidate[1]), db = distance(best[1]);
    if (Math.abs(da - db) > epsilon ? da < db : all.indexOf(candidate[0]) < all.indexOf(best[0])) best = candidate;
  }
  return best?.[0];
}

/** Pane frames within `bounds`, with `gap` points between siblings for their divider. */
export function splitFrames(layout: SplitLayout, bounds: Rect, gap = 0): Map<string, Rect> {
  const result = new Map<string, Rect>();
  walk(layout.root, bounds, gap, true, [], (node, frame) => {
    if (node.type === "leaf") result.set(node.leaf, frame);
  });
  return result;
}

export function splitDividers(layout: SplitLayout, bounds: Rect, gap = 0): SplitDivider[] {
  const result: SplitDivider[] = [];
  walk(layout.root, bounds, gap, true, [], (node, frame, path) => {
    if (node.type !== "split") return;
    const [first] = divide(frame, node.axis, node.ratio, gap, true);
    const divider = node.axis === "horizontal"
      ? { x: first.x + first.width, y: frame.y, width: gap, height: frame.height }
      : { x: frame.x, y: first.y + first.height, width: frame.width, height: gap };
    result.push({ path, axis: node.axis, ratio: node.ratio, frame: divider, container: frame });
  });
  return result;
}

export function setSplitRatio(layout: SplitLayout, ratio: number, path: number[]): void {
  const node = nodeAt(layout, path);
  if (node?.type !== "split") return;
  const clamped = Math.min(1 - SPLIT_MINIMUM_RATIO, Math.max(SPLIT_MINIMUM_RATIO, ratio));
  layout.root = replacing(layout.root, path, { ...node, ratio: clamped });
}

/** Moves the nearest enclosing divider on the matching axis by `points`, as `resize_split` does. Clears any zoom. */
export function resizeSplit(layout: SplitLayout, leaf: string, direction: SplitDirection, points: number, bounds: Rect): boolean {
  const path = pathTo(layout, leaf);
  if (!path) return false;
  const axis: SplitAxis = direction === "left" || direction === "right" ? "horizontal" : "vertical";
  for (let length = path.length - 1; length >= 0; length--) {
    const parent = path.slice(0, length);
    const node = nodeAt(layout, parent);
    if (node?.type !== "split" || node.axis !== axis) continue;
    const divider = splitDividers(layout, bounds).find((d) => d.path.length === parent.length && d.path.every((v, i) => v === parent[i]));
    if (!divider) continue;
    const extent = axis === "horizontal" ? divider.container.width : divider.container.height;
    if (extent <= 0) return false;
    const delta = (points / extent) * (direction === "left" || direction === "up" ? -1 : 1);
    setSplitRatio(layout, node.ratio + delta, parent);
    layout.zoomed = null;
    return true;
  }
  return false;
}

function weight(node: SplitNode, axis: SplitAxis): number {
  if (node.type !== "split" || node.axis !== axis) return 1;
  return weight(node.first, axis) + weight(node.second, axis);
}

function equalized(node: SplitNode): SplitNode {
  if (node.type !== "split") return node;
  const a = weight(node.first, node.axis), b = weight(node.second, node.axis);
  return { ...node, ratio: a / (a + b), first: equalized(node.first), second: equalized(node.second) };
}

/** Gives every pane along each axis an equal share, as `equalize_splits` does. */
export function equalizeSplits(layout: SplitLayout): void {
  layout.root = equalized(layout.root);
}
