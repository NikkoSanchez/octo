import { create } from "zustand";
import { DEFERRED_NOTICE, hasStaged, hasWorking, type ChangedFile, type DiffStat } from "@octo/git/model";
import type { CodeAttachment, DiffScope, ReviewSnapshot } from "@octo/core";
import { call } from "../bridge";

export type DiffLayout = "stacked" | "sideBySide";

/** One checkout's Changes: the Git file list, every diff, and the file the header follows. */
export interface CheckoutReview {
  projectID: string;
  files: ChangedFile[];
  branch: string;
  /** Every tracked and untracked path, for Files and ⌘P. */
  paths: string[];
  /** Tracked-file line counts against HEAD; undefined before the first read or in an unborn repository. */
  diffStat?: DiffStat;
  stagedStat?: DiffStat;
  workingStat?: DiffStat;
  /** Every change, Staged then Unstaged, for the continuous diff. */
  changeSnapshots: ReviewSnapshot[];
  /** The row chosen in the list. Nothing is chosen by default. */
  selectedPath?: string;
  scope: DiffScope;
  /** The file the diff header shows: the chosen one, or the one scrolled to the top. */
  current?: ReviewSnapshot;
  /** Asks the continuous diff to scroll a file to the top; a list click changes the request. */
  reveal?: { index: number; request: number };
  /** The code selected in the diff, attached by Ask Agent or ⇧⌘A. */
  selection?: CodeAttachment;
  /** The code selected in the Files editor. */
  fileSelection?: CodeAttachment;
  loading: boolean;
  loadingSnapshot: boolean;
  error?: string;
}

interface ReviewState {
  checkouts: Record<string, CheckoutReview>;
  diffLayout: DiffLayout;
  /** Soft-wraps long lines in diffs and the Files editor instead of scrolling sideways. */
  wrapLines: boolean;
}

export const useReview = create<ReviewState>(() => ({ checkouts: {}, diffLayout: "stacked", wrapLines: false }));

const empty = (projectID: string): CheckoutReview => ({
  projectID, files: [], branch: "", paths: [], changeSnapshots: [], scope: "working", loading: false, loadingSnapshot: false,
});

function update(root: string, change: Partial<CheckoutReview> | ((review: CheckoutReview) => Partial<CheckoutReview>)): void {
  useReview.setState((s) => {
    const current = s.checkouts[root];
    if (!current) return s;
    return { checkouts: { ...s.checkouts, [root]: { ...current, ...(typeof change === "function" ? change(current) : change) } } };
  });
}

export function reviewFor(root: string | undefined): CheckoutReview | undefined {
  return root ? useReview.getState().checkouts[root] : undefined;
}

// Results for a superseded refresh or selection are dropped.
const refreshes = new Map<string, number>();
const selections = new Map<string, number>();
let revealRequests = 0;

/** Reads the checkout's changes and every diff. A chosen row survives while its file and group still have changes. */
export async function refreshReview(projectID: string, root: string): Promise<void> {
  const token = (refreshes.get(root) ?? 0) + 1;
  refreshes.set(root, token);
  const current = (() => refreshes.get(root) === token);
  useReview.setState((s) => {
    const existing = s.checkouts[root];
    const next = existing && existing.projectID === projectID ? existing : empty(projectID);
    return { checkouts: { ...s.checkouts, [root]: { ...next, loading: true } } };
  });
  try {
    const data = await call("review", "refresh", root);
    if (!current()) return;
    const entries = [
      ...data.files.filter(hasStaged).map((file) => ({ file, scope: "staged" as const })),
      ...data.files.filter(hasWorking).map((file) => ({ file, scope: "working" as const })),
    ];
    const snapshots = await call("review", "snapshots", entries, projectID, root);
    if (!current()) return;
    update(root, (review) => {
      const selectedPath = review.selectedPath && snapshots.some((s) => s.path === review.selectedPath && s.scope === review.scope) ? review.selectedPath : undefined;
      const keep = review.current && snapshots.find((s) => s.path === review.current!.path && s.scope === review.current!.scope);
      const sameIDs = snapshots.length === review.changeSnapshots.length && snapshots.every((s, i) => s.id === review.changeSnapshots[i].id);
      return {
        files: data.files, branch: data.branch, paths: data.paths,
        diffStat: data.diffStat, stagedStat: data.stagedStat, workingStat: data.workingStat,
        // Unchanged diffs keep their objects, so Pierre keeps its rendered files.
        changeSnapshots: sameIDs ? review.changeSnapshots : snapshots,
        selectedPath, current: keep ?? snapshots[0],
        selection: sameIDs ? review.selection : undefined,
        loading: false, error: undefined,
      };
    });
  } catch (error) {
    if (current()) update(root, { loading: false, error: String(error instanceof Error ? error.message : error), files: [], changeSnapshots: [], current: undefined });
  }
}

/** Choosing a row scrolls the continuous diff to that file; side by side shows it alone. */
export async function selectChange(root: string, file: ChangedFile, requested: DiffScope): Promise<void> {
  const review = reviewFor(root);
  if (!review) return;
  const scope: DiffScope = requested === "staged" && !hasStaged(file) ? "working" : requested === "working" && !hasWorking(file) && hasStaged(file) ? "staged" : requested;
  const token = (selections.get(root) ?? 0) + 1;
  selections.set(root, token);
  const index = review.changeSnapshots.findIndex((s) => s.path === file.path && s.scope === scope);
  if (index >= 0) {
    update(root, { selectedPath: file.path, scope, selection: undefined, current: review.changeSnapshots[index], reveal: { index, request: ++revealRequests }, loadingSnapshot: false });
    // A file past the continuous diff's line limit is read on its own for side by side.
    if (review.changeSnapshots[index].notice !== DEFERRED_NOTICE) return;
  }
  update(root, { selectedPath: file.path, scope, selection: undefined, loadingSnapshot: true });
  try {
    const snapshot = await call("review", "snapshot", file, review.projectID, root, scope);
    if (selections.get(root) === token) update(root, { current: snapshot, loadingSnapshot: false, error: undefined });
  } catch (error) {
    if (selections.get(root) === token) update(root, { loadingSnapshot: false, error: String(error instanceof Error ? error.message : error) });
  }
}

/** The continuous diff scrolled another file to the top. A chosen row follows it. */
export function showVisibleFile(root: string, index: number): void {
  const review = reviewFor(root);
  const file = review?.changeSnapshots[index];
  if (!review || !file || review.current?.id === file.id) return;
  update(root, review.selectedPath ? { current: file, selectedPath: file.path, scope: file.scope } : { current: file });
}

/** Shows the chosen file's other scope, when it has changes there. */
export async function toggleScope(root: string): Promise<void> {
  const review = reviewFor(root);
  const file = review?.files.find((f) => f.path === review.selectedPath);
  if (!review || !file) return;
  const other: DiffScope = review.scope === "working" ? "staged" : "working";
  if (other === "staged" ? hasStaged(file) : hasWorking(file)) await selectChange(root, file, other);
}

export function setDiffLayout(layout: DiffLayout): void {
  useReview.setState((s) => {
    if (s.diffLayout === layout) return s;
    const checkouts = Object.fromEntries(Object.entries(s.checkouts).map(([root, review]) => [root, { ...review, selection: undefined }]));
    return { diffLayout: layout, checkouts };
  });
}

export function toggleWrapLines(): void {
  useReview.setState((s) => ({ wrapLines: !s.wrapLines }));
}

export function setCodeSelection(root: string, selection: CodeAttachment | undefined, surface: "changes" | "files" = "changes"): void {
  update(root, surface === "files" ? { fileSelection: selection } : { selection });
}
