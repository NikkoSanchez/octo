import type { DiffScope } from "@octo/core";

export interface ChangedFile {
  path: string;
  indexStatus: string;
  worktreeStatus: string;
  /** A rename or copy's source path, which unstaging restores alongside `path`. */
  originalPath?: string;
}

export const isUntracked = (f: ChangedFile) => f.indexStatus === "?";
export const hasStaged = (f: ChangedFile) => f.indexStatus !== " " && f.indexStatus !== "?";
export const hasWorking = (f: ChangedFile) => f.worktreeStatus !== " ";

/**
 * Hunks can be staged or unstaged only for an ordinary modification in that scope; additions,
 * deletions, renames and untracked files move as whole files.
 */
export function supportsHunkStaging(file: ChangedFile, scope: DiffScope): boolean {
  if (scope === "working") return file.indexStatus !== "?" && file.worktreeStatus === "M";
  if (scope === "staged") return file.indexStatus === "M";
  return false;
}

export interface DiffStat {
  additions: number;
  deletions: number;
  /** Per checkout-relative path. Binary files and renames are counted in the totals only. */
  files: Record<string, { additions: number; deletions: number }>;
}

export interface UpstreamStatus {
  /** Undefined while HEAD is detached. */
  branch?: string;
  /** For example `origin/main`; undefined when the branch tracks nothing. */
  upstream?: string;
  upstreamRemote?: string;
  /** Commits to push. Without a live upstream, commits that no remote-tracking branch contains. */
  ahead: number;
  behind: number;
  /** The upstream is configured but its remote branch no longer exists. */
  upstreamGone: boolean;
  remotes: string[];
  hasCommits: boolean;
}

/** Where Push sends the branch: its upstream's remote, else origin, else the only remote. */
export function pushRemote(status: UpstreamStatus): string | undefined {
  return status.upstreamRemote ?? (status.remotes.includes("origin") ? "origin" : status.remotes.length === 1 ? status.remotes[0] : undefined);
}
/** A branch without a live upstream is published (and then tracked) on its first push. */
export const publishes = (s: UpstreamStatus) => s.upstream === undefined || s.upstreamGone;
export const canPush = (s: UpstreamStatus) => s.branch !== undefined && s.hasCommits && pushRemote(s) !== undefined && (publishes(s) || s.ahead > 0);

export interface GitStash {
  index: number;
  /** The stash commit, checked again before Apply, Pop or Drop because `stash@{n}` shifts. */
  commit: string;
  message: string;
  branch?: string;
  date: number;
}
export const stashReference = (s: GitStash) => `stash@{${s.index}}`;

export interface CommitSummary { hash: string; subject: string }

/** Shown for files past the continuous diff's line limit; selecting such a file loads its diff alone. */
export const DEFERRED_NOTICE = "Not shown here: Changes lists up to 20,000 lines at once. Choose side by side or open the file to review it.";

export interface PullRequest {
  number: number;
  url: string;
  title: string;
  isDraft: boolean;
  baseRefName: string;
}
