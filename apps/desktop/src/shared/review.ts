import type { ChangedFile, DiffStat } from "@octo/git";

/** Main → renderer review events, tagged with the checkout they describe. */
export type ReviewEvent = { type: "gitChanged"; root: string };

export interface ReviewRefresh {
  files: ChangedFile[];
  branch: string;
  paths: string[];
  diffStat?: DiffStat;
  stagedStat?: DiffStat;
  workingStat?: DiffStat;
}

export interface OpenedFile {
  text: string;
  /** Bytes on disk as UTF-8 text when the file was opened or last saved. */
  baseline: string;
}

/** A failed Git action: what happened, what to do next, and Git's own output. */
export interface GitProblem {
  title: string;
  hint?: string;
  detail?: string;
}

export function pullHint(detail: string): string {
  const lower = detail.toLowerCase();
  if (lower.includes("not possible to fast-forward") || lower.includes("diverg")) return "This branch and its upstream both have new commits. Merge or rebase in the terminal.";
  if (lower.includes("would be overwritten") || lower.includes("untracked working tree files")) return "Local changes touch the same files. Commit or stash them, then pull again.";
  if (lower.includes("terminal prompts disabled") || lower.includes("authentication failed") || lower.includes("permission denied")) {
    return "Git needs credentials it can use without a terminal, such as a credential helper or an SSH agent.";
  }
  if (lower.includes("could not resolve host") || lower.includes("unable to access") || lower.includes("could not read from remote")) {
    return "Check your network connection and access to the remote, then try again.";
  }
  return "Git's output is below.";
}

/** Push failures keep the local commits; the hint says what usually fixes each kind. */
export function pushProblem(detail: string, destination: string, commits: number, timedOut = false): GitProblem {
  const lower = detail.toLowerCase();
  const saved = commits === 1 ? "Your commit is saved locally." : commits > 1 ? `Your ${commits} commits are saved locally.` : "Your commits are saved locally.";
  let hint: string;
  if (lower.includes("non-fast-forward") || lower.includes("fetch first") || lower.includes("[rejected]")) {
    hint = "The remote branch has commits this checkout doesn't. Pull or rebase in the terminal, then push again.";
  } else if (lower.includes("terminal prompts disabled") || lower.includes("authentication failed") || lower.includes("permission denied") || lower.includes("could not read username")) {
    hint = "Git needs credentials it can use without a terminal, such as a credential helper or an SSH agent.";
  } else if (lower.includes("hook")) {
    hint = "A pre-push hook stopped the push. Its output is below.";
  } else if (timedOut || lower.includes("exceeded its time limit")) {
    hint = "The push did not finish within five minutes.";
  } else if (lower.includes("could not resolve host") || lower.includes("unable to access") || lower.includes("could not read from remote")) {
    hint = "Check your network connection and access to the remote, then retry.";
  } else {
    hint = "Fix the problem below, then retry.";
  }
  return { title: `Couldn't push to ${destination}. ${saved}`, hint, detail };
}

export function stashHint(detail: string): string {
  return detail.includes("--index")
    ? "The stash's staged changes conflict with the current index. Commit or stash your current changes first. The stash was kept."
    : "The stash was kept. Resolve any conflicts in the terminal, or commit or stash your current changes and try again.";
}
