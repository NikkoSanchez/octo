import { useEffect, useState } from "react";
import { ArrowDown, ArrowUp, CircleCheck, Ellipsis, GitPullRequest, RotateCw, TriangleAlert, X } from "lucide-react";
import { canPush, hasStaged, hasWorking, isUntracked, publishes, pushRemote, type ChangedFile } from "@octo/git/model";
import type { GitProblem } from "../../../../shared/review";
import { useReview } from "../../state/review";
import {
  commits, discard, fetchRemote, fileName, filesLabel, pull, pullRequestFor, push, refreshCheckout, stage, unstage, updateGit, useGit,
} from "../../state/git";
import { popup } from "../../lib/menu";
import { call } from "../../bridge";
import { CapsuleButton, Spinner, ToolbarButton } from "../controls";
import { GitBranchIcon } from "../icons";
import { GitSheets } from "./GitSheets";
import styles from "./review.module.css";

/**
 * The Changes tab's Git row: the branch over its upstream state, then Pull (when behind), Push,
 * Create PR and more actions. Pulling, pushing and publishing happen only from these explicit buttons.
 */
export function GitHeader({ projectID, root }: { projectID: string; root: string }) {
  const review = useReview((s) => s.checkouts[root]);
  const git = useGit((s) => s.checkouts[root]);
  const files = review?.files ?? [];
  const status = git?.status;
  const unstagedFiles = files.filter(hasWorking), stagedFiles = files.filter(hasStaged);
  const request = git && pullRequestFor(git);
  const remote = status && pushRemote(status);

  const pushTitle = !status ? "Push" : publishes(status) && status.ahead === 0 ? "Publish" : status.ahead > 0 ? `Push ${status.ahead}` : "Push";
  const pushHelp = !status?.branch ? "Check out a branch to push" : !status.hasCommits ? "Commit before pushing"
    : !remote ? (status.remotes.length === 0 ? "This repository has no remote" : "Several remotes and no origin: push from the terminal")
    : publishes(status) ? `Publish ${status.branch} to ${remote} and track it`
    : status.ahead > 0 ? `Push ${commits(status.ahead)} to ${status.upstream ?? remote}` : `Up to date with ${status.upstream ?? remote}`;
  const statusText = !status ? " "
    : !status.branch ? "Detached HEAD · check out a branch to push"
    : !status.hasCommits ? "No commits yet"
    : status.upstream && status.upstreamGone ? `${status.upstream} no longer exists · Push publishes it again`
    : !status.upstream ? (!remote ? (status.remotes.length === 0 ? "No remote" : "Not published") : `Not on ${remote}` + (status.ahead > 0 ? ` · ${commits(status.ahead)} to publish` : ""))
    : [status.upstream, status.ahead > 0 && `${commits(status.ahead)} to push`, status.behind > 0 && `${status.behind} behind`, status.ahead === 0 && status.behind === 0 && "Up to date"].filter(Boolean).join(" · ");

  const moreMenu = (anchor: Element) => void popup([
    { label: "Stage All", enabled: unstagedFiles.length > 0, action: () => void stage(projectID, root, unstagedFiles) },
    { label: "Unstage All", enabled: stagedFiles.length > 0, action: () => void unstage(projectID, root, stagedFiles) },
    { type: "separator" },
    { label: "Stash Changes…", enabled: files.length > 0, action: () => updateGit(root, { sheet: "newStash" }) },
    { label: git?.stashes.length ? `Stashes (${git.stashes.length})…` : "Stashes…", action: () => updateGit(root, { sheet: "stashes" }) },
    { label: "Pull", enabled: !!status?.upstream && !status.upstreamGone, action: () => void pull(projectID, root) },
    { label: "Fetch", enabled: (status?.remotes.length ?? 0) > 0, action: () => void fetchRemote(projectID, root) },
    { type: "separator" },
    { label: "Discard All Unstaged Changes…", enabled: unstagedFiles.length > 0, action: () => updateGit(root, { discardRequest: unstagedFiles }) },
  ], anchor);

  return (
    <div className={styles.gitHeader}>
      <div className={styles.gitRow}>
        <span className={styles.secondaryIcon}><GitBranchIcon size={14} /></span>
        <div className={styles.branch} title={review?.branch}>
          <strong>{review?.branch || "No branch"}</strong>
          {git?.notice ? <small className={styles.gitNotice}><CircleCheck size={11} />{git.notice}</small> : <small>{statusText}</small>}
        </div>
        <span className={styles.spacer} />
        {(review?.loading || git?.activity) && <span title={git?.activity ?? "Refreshing"}><Spinner /></span>}
        {status && status.behind > 0 && !publishes(status) && (
          <CapsuleButton disabled={!!git?.activity} help={`Fast-forward to ${status.upstream ?? "the upstream"} (${commits(status.behind)})`}
            onClick={() => void pull(projectID, root)}><ArrowDown size={11} />Pull {status.behind}</CapsuleButton>
        )}
        {/* Without a remote there is nowhere to publish, so neither action is offered. */}
        {remote && <>
          <CapsuleButton disabled={!status || !canPush(status) || !!git?.activity} help={pushHelp} onClick={() => void push(projectID, root)}><ArrowUp size={11} />{pushTitle}</CapsuleButton>
          <CapsuleButton disabled={!status?.branch || !status.hasCommits} help={request ? "View this branch's pull request" : "Create a GitHub pull request for this branch"}
            onClick={() => updateGit(root, { sheet: "pullRequest" })}><GitPullRequest size={11} />{request ? `PR #${request.number}` : "Create PR"}</CapsuleButton>
        </>}
        <ToolbarButton aria-label="More Git actions" help="More Git actions" onClick={(e) => moreMenu(e.currentTarget)}><Ellipsis size={15} /></ToolbarButton>
        <ToolbarButton aria-label="Refresh changes" help="Refresh changes (⇧⌘R)" onClick={() => void refreshCheckout(projectID, root)}><RotateCw size={14} /></ToolbarButton>
      </div>
      {git?.pushProblem && (
        <GitBanner problem={git.pushProblem} retry={status && canPush(status) ? () => void push(projectID, root) : undefined} dismiss={() => updateGit(root, { pushProblem: undefined })} />
      )}
      {git?.problem && !git.sheet && <GitBanner problem={git.problem} dismiss={() => updateGit(root, { problem: undefined })} />}
      <GitSheets projectID={projectID} root={root} />
      <DiscardConfirmation projectID={projectID} root={root} files={git?.discardRequest} />
    </div>
  );
}

/** An actionable failure. A hint leads, with Git's own output available beneath it. */
export function GitBanner({ problem, retry, dismiss }: { problem: GitProblem; retry?: () => void; dismiss: () => void }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className={styles.banner} role="alert">
      <div className={styles.bannerRow}>
        <TriangleAlert size={12} className={styles.bannerIcon} />
        <div className={styles.bannerText}>
          <strong>{problem.title}</strong>
          {problem.hint ? <small>{problem.hint}</small> : problem.detail && <small className={styles.bannerDetail}>{problem.detail}</small>}
        </div>
        {retry && <CapsuleButton onClick={retry}>Retry</CapsuleButton>}
        <button type="button" className={styles.bannerClose} aria-label="Dismiss" title="Dismiss" onClick={dismiss}><X size={10} strokeWidth={3} /></button>
      </div>
      {problem.hint && problem.detail && (
        <details className={styles.bannerOutput} open={expanded} onToggle={(e) => setExpanded(e.currentTarget.open)}>
          <summary>Git output</summary>
          <pre>{problem.detail}</pre>
        </details>
      )}
    </div>
  );
}

/** Staged changes are kept; Git can't recover the discarded edits, so this always asks. */
function DiscardConfirmation({ projectID, root, files }: { projectID: string; root: string; files?: ChangedFile[] }) {
  useEffect(() => {
    if (!files?.length) return;
    let active = true;
    const untracked = files.filter(isUntracked);
    let detail = "Staged changes are kept. ";
    if (files.length === 1) {
      detail += untracked.length ? "This deletes the untracked file from the checkout." : "This restores the file to its staged or committed version.";
    } else {
      const tracked = files.length - untracked.length;
      detail += tracked === 0 ? "This deletes" : `This restores ${filesLabel(tracked)} to their staged or committed versions`;
      detail += untracked.length === 0 ? ":" : (tracked === 0 ? ` ${untracked.length} untracked ` : ` and deletes ${untracked.length} untracked `) + (untracked.length === 1 ? "file:" : "files:");
      detail += "\n\n" + files.slice(0, 8).map((f) => f.path).join("\n") + (files.length > 8 ? `\n…and ${files.length - 8} more` : "");
    }
    detail += "\n\nGit can't recover these edits.";
    void call("app", "confirm", {
      message: files.length === 1 ? `Discard changes to ${fileName(files[0])}?` : "Discard all unstaged changes?",
      detail, buttons: ["Cancel", "Discard Changes"], destructive: 1,
    }).then((choice) => {
      if (!active) return;
      updateGit(root, { discardRequest: undefined });
      if (choice === 1) void discard(projectID, root, files);
    });
    return () => { active = false; };
  }, [files, projectID, root]);
  return null;
}

