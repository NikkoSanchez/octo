import { create } from "zustand";
import type { CommitMessageModel } from "@octo/agents/model";
import type { ReviewSnapshot } from "@octo/core";
import { pushRemote, type ChangedFile, type CommitSummary, type GitStash, type PullRequest, type UpstreamStatus } from "@octo/git/model";
import { pullHint, pushProblem, stashHint, type GitProblem } from "../../../shared/review";
import { call } from "../bridge";
import { refreshReview } from "./review";

export type GitSheet = "stashes" | "newStash" | "pullRequest";

/** One checkout's Git workflow: upstream state, stashes, the running action and its outcome. */
export interface CheckoutGit {
  status?: UpstreamStatus;
  stashes: GitStash[];
  /** The running action, for the progress indicator. */
  activity?: string;
  problem?: GitProblem;
  /** Kept apart from other errors: the banner offers Retry and says the commits are safe. */
  pushProblem?: GitProblem;
  lastCommit?: CommitSummary;
  notice?: string;
  /** Open pull requests by branch, filled when looked up or created. */
  pullRequests: Record<string, PullRequest>;
  /** The commit message draft; kept while nothing is staged. */
  draft: string;
  /** The model writing a commit message, while one does. */
  drafting?: CommitMessageModel;
  sheet?: GitSheet;
  /** Files awaiting confirmation before their unstaged edits are discarded. */
  discardRequest?: ChangedFile[];
}

export const useGit = create<{ checkouts: Record<string, CheckoutGit> }>(() => ({ checkouts: {} }));

const blank = (): CheckoutGit => ({ stashes: [], pullRequests: {}, draft: "" });

export function gitFor(root: string | undefined): CheckoutGit {
  return (root && useGit.getState().checkouts[root]) || blank();
}

export function updateGit(root: string, change: Partial<CheckoutGit> | ((git: CheckoutGit) => Partial<CheckoutGit>)): void {
  useGit.setState((s) => {
    const current = s.checkouts[root] ?? blank();
    return { checkouts: { ...s.checkouts, [root]: { ...current, ...(typeof change === "function" ? change(current) : change) } } };
  });
}

export function pullRequestFor(git: CheckoutGit): PullRequest | undefined {
  return git.status?.branch ? git.pullRequests[git.status.branch] : undefined;
}

/** Reads upstream and stash state. */
export async function loadGit(root: string): Promise<void> {
  const [status, stashes] = await Promise.all([
    call("review", "upstreamStatus", root).catch(() => undefined),
    call("review", "stashes", root).catch(() => [] as GitStash[]),
  ]);
  updateGit(root, { status, stashes });
}

/** Refreshes Changes and the Git row together, as after any action. */
export async function refreshCheckout(projectID: string, root: string): Promise<void> {
  await Promise.all([refreshReview(projectID, root), loadGit(root)]);
}

const tails = new Map<string, Promise<boolean>>();
const noticeTimers = new Map<string, ReturnType<typeof setTimeout>>();

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

/** Runs after any earlier action on this checkout finishes, then refreshes Changes and upstream state. */
function perform(projectID: string, root: string, label: string, failure: string, body: () => Promise<void>): Promise<boolean> {
  const previous = tails.get(root) ?? Promise.resolve(true);
  const task = previous.catch(() => false).then(async () => {
    updateGit(root, { activity: label, problem: undefined });
    let succeeded = false;
    try { await body(); succeeded = true; }
    catch (error) { updateGit(root, { problem: { title: failure, detail: message(error) } }); }
    await refreshCheckout(projectID, root);
    updateGit(root, { activity: undefined });
    return succeeded;
  });
  tails.set(root, task);
  return task;
}

function announce(root: string, text: string): void {
  updateGit(root, { notice: text });
  clearTimeout(noticeTimers.get(root));
  noticeTimers.set(root, setTimeout(() => updateGit(root, { notice: undefined }), 4000));
}

export const fileName = (file: ChangedFile) => file.path.split("/").at(-1) ?? file.path;

// MARK: Index

export function stage(projectID: string, root: string, files: ChangedFile[]): Promise<boolean> {
  const paths = files.flatMap((f) => f.originalPath ? [f.path, f.originalPath] : [f.path]);
  if (!paths.length) return Promise.resolve(false);
  return perform(projectID, root, "Staging…", files.length === 1 ? `Couldn't stage ${fileName(files[0])}` : "Couldn't stage changes",
    () => call("review", "stage", paths, root));
}

export function unstage(projectID: string, root: string, files: ChangedFile[]): Promise<boolean> {
  if (!files.length) return Promise.resolve(false);
  return perform(projectID, root, "Unstaging…", files.length === 1 ? `Couldn't unstage ${fileName(files[0])}` : "Couldn't unstage changes",
    () => call("review", "unstage", files, root));
}

export function applyHunk(projectID: string, root: string, snapshot: ReviewSnapshot, hunk: number): Promise<boolean> {
  const staging = snapshot.scope !== "staged";
  return perform(projectID, root, staging ? "Staging hunk…" : "Unstaging hunk…", staging ? "Couldn't stage this hunk" : "Couldn't unstage this hunk",
    () => call("review", "applyHunk", snapshot, hunk, root));
}

/** Called only from the discard confirmation. */
export async function discard(projectID: string, root: string, files: ChangedFile[]): Promise<void> {
  if (!files.length) return;
  if (await perform(projectID, root, "Discarding…", "Couldn't discard changes", () => call("review", "discard", files, root))) {
    announce(root, "Unstaged changes discarded. Staged changes kept.");
  }
}

// MARK: Commit and publish

export async function commit(projectID: string, root: string, text: string): Promise<boolean> {
  let summary: CommitSummary | undefined;
  const succeeded = await perform(projectID, root, "Committing…", "Couldn't commit", async () => { summary = await call("review", "commit", text, root); });
  if (succeeded) updateGit(root, { lastCommit: summary, draft: "" });
  return succeeded;
}

export async function push(projectID: string, root: string): Promise<void> {
  const status = gitFor(root).status;
  const destination = status?.upstream ?? (status && pushRemote(status)) ?? "the remote";
  const commits = status?.ahead ?? 0;
  let failure: { error?: string; timedOut?: boolean } = {};
  await perform(projectID, root, "Pushing…", "Couldn't push", async () => { failure = await call("review", "push", root); });
  if (failure.error) updateGit(root, { pushProblem: pushProblem(failure.error, destination, commits, failure.timedOut) });
  else if (!gitFor(root).problem) {
    updateGit(root, { pushProblem: undefined });
    announce(root, `Pushed to ${gitFor(root).status?.upstream ?? destination}.`);
  }
}

/** Fast-forward only: Pull never starts a merge or rebase that would need conflict resolution. */
export async function pull(projectID: string, root: string): Promise<void> {
  const source = gitFor(root).status?.upstream ?? "the remote";
  if (await perform(projectID, root, "Pulling…", `Couldn't pull from ${source}. Nothing was changed.`, () => call("review", "pull", root))) {
    announce(root, `Pulled from ${source}.`);
  } else {
    updateGit(root, (git) => git.problem ? { problem: { ...git.problem, hint: pullHint(git.problem.detail ?? "") } } : {});
  }
}

export async function fetchRemote(projectID: string, root: string): Promise<void> {
  if (await perform(projectID, root, "Fetching…", "Couldn't fetch", () => call("review", "fetch", root))) {
    const status = gitFor(root).status;
    announce(root, `Fetched from ${status?.upstreamRemote ?? (status && pushRemote(status)) ?? "the remote"}.`);
  }
}

// MARK: Commit messages

let draftRequests = 0;

/** Writes a message for what is staged now. Returns undefined when cancelled, failed (shown as a problem) or superseded. */
export async function draftMessage(root: string, candidates: CommitMessageModel[]): Promise<string | undefined> {
  cancelDraft(root);
  if (!candidates.length) return undefined;
  const request = `${root}\0${++draftRequests}`;
  activeDrafts.set(root, request);
  updateGit(root, { drafting: candidates[0], problem: undefined });
  const result = await call("review", "generateCommitMessage", root, candidates, request).catch((error) => ({ error: message(error) }) as { message?: string; error?: string; cancelled?: boolean });
  if (activeDrafts.get(root) !== request) return undefined;
  activeDrafts.delete(root);
  updateGit(root, { drafting: undefined });
  if (result.message) return result.message;
  if (result.error) {
    updateGit(root, { problem: {
      title: "Couldn't write a commit message",
      hint: "Choose another model from the menu beside Generate, or check the CLI's sign-in in Settings → Agents.",
      detail: result.error,
    } });
  }
  return undefined;
}

const activeDrafts = new Map<string, string>();

export function cancelDraft(root: string): void {
  const request = activeDrafts.get(root);
  if (request === undefined) return;
  activeDrafts.delete(root);
  updateGit(root, { drafting: undefined });
  void call("review", "cancelCommitMessage", request);
}

// MARK: Stashes

export async function stash(projectID: string, root: string, name: string, includeUntracked: boolean): Promise<boolean> {
  const succeeded = await perform(projectID, root, "Stashing…", "Couldn't stash changes", () => call("review", "stash", name, includeUntracked, root));
  if (succeeded) announce(root, `Stashed “${name}”.`);
  return succeeded;
}

export async function applyStash(projectID: string, root: string, entry: GitStash, pop: boolean): Promise<boolean> {
  const succeeded = await perform(projectID, root, pop ? "Popping stash…" : "Applying stash…",
    pop ? `Couldn't pop “${entry.message}”` : `Couldn't apply “${entry.message}”`, () => call("review", "applyStash", entry, pop, root));
  if (succeeded) announce(root, pop ? "Stash popped. Changes restored." : "Stash applied. The saved copy is kept.");
  else updateGit(root, (git) => git.problem ? { problem: { ...git.problem, hint: stashHint(git.problem.detail ?? "") } } : {});
  return succeeded;
}

export async function dropStash(projectID: string, root: string, entry: GitStash): Promise<void> {
  if (await perform(projectID, root, "Dropping stash…", `Couldn't drop “${entry.message}”`, () => call("review", "dropStash", entry, root))) {
    announce(root, "Stash dropped.");
  }
}

// MARK: Pull requests

export async function lookUpPullRequest(root: string): Promise<PullRequest | undefined> {
  const branch = gitFor(root).status?.branch;
  if (!branch) return undefined;
  const request = await call("review", "openPullRequest", branch, root);
  if (request) updateGit(root, (git) => ({ pullRequests: { ...git.pullRequests, [branch]: request } }));
  return request ?? undefined;
}

export async function baseBranches(root: string): Promise<{ branches: string[]; defaultBranch?: string }> {
  const status = gitFor(root).status;
  const remote = status && pushRemote(status);
  if (!remote) return { branches: [] };
  try {
    const result = await call("review", "remoteBranches", remote, root);
    return { branches: result.branches.filter((b) => b !== status?.branch), defaultBranch: result.defaultBranch };
  } catch { return { branches: [] }; }
}

/** One commit titles the pull request; several are listed in its description. */
export async function pullRequestDraft(root: string, base: string): Promise<{ title: string; body: string }> {
  const status = gitFor(root).status;
  const remote = status && pushRemote(status);
  const subjects = await call("review", "commitSubjects", (remote ? `${remote}/` : "") + base, root).catch(() => [] as string[]);
  if (subjects.length === 1) return { title: subjects[0], body: "" };
  const title = (status?.branch ?? "").split("/").at(-1)?.replace(/[-_]/g, " ") ?? "";
  const body = subjects.length ? "## Changes\n" + [...subjects].reverse().map((s) => `- ${s}`).join("\n") : "";
  return { title: title.charAt(0).toUpperCase() + title.slice(1), body };
}

export async function createPullRequest(root: string, title: string, body: string, base: string, draft: boolean): Promise<PullRequest> {
  const branch = gitFor(root).status?.branch;
  if (!branch) throw new Error("Check out a branch first.");
  const request = await call("review", "createPullRequest", title, body, base, branch, draft, root);
  updateGit(root, (git) => ({ pullRequests: { ...git.pullRequests, [branch]: request } }));
  return request;
}

export const commits = (count: number) => count === 1 ? "1 commit" : `${count} commits`;
export const filesLabel = (count: number) => count === 1 ? "1 file" : `${count} files`;
