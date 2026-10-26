import { useEffect, useState } from "react";
import { ArrowUp, ArrowUpCircle, Compass, GitPullRequest, Info, Inbox, TriangleAlert } from "lucide-react";
import { canPush, isUntracked, publishes, pushRemote, stashReference, type GitStash, type PullRequest } from "@octo/git/model";
import { useReview } from "../../state/review";
import {
  applyStash, baseBranches, commits, createPullRequest, dropStash, gitFor, lookUpPullRequest, pullRequestDraft, push, stash, updateGit, useGit,
} from "../../state/git";
import { call, run } from "../../bridge";
import { BorderedButton, PrimaryButton, Spinner } from "../controls";
import { Sheet } from "../overlays/Sheet";
import { GitBanner } from "./GitHeader";
import styles from "./review.module.css";

/** Stashes, a new stash, and pull requests, each as a sheet over the window. */
export function GitSheets({ projectID, root }: { projectID: string; root: string }) {
  const sheet = useGit((s) => s.checkouts[root]?.sheet);
  const close = () => updateGit(root, { sheet: undefined });
  switch (sheet) {
    case "stashes": return <Sheet label="Stashes" width={480} close={close}><Stashes projectID={projectID} root={root} close={close} /></Sheet>;
    case "newStash": return <Sheet label="Stash Changes" width={420} close={close}><NewStash projectID={projectID} root={root} close={close} /></Sheet>;
    case "pullRequest": return <Sheet label="Pull Request" width={520} close={close}><PullRequestSheet projectID={projectID} root={root} close={close} /></Sheet>;
    default: return null;
  }
}

function Stashes({ projectID, root, close }: { projectID: string; root: string; close: () => void }) {
  const git = useGit((s) => s.checkouts[root]);
  const canStash = useReview((s) => (s.checkouts[root]?.files.length ?? 0) > 0);
  const drop = async (entry: GitStash) => {
    const choice = await call("app", "confirm", { message: `Drop “${entry.message}”?`, detail: "The saved copy will be removed. Changes already applied to the checkout stay.", buttons: ["Cancel", "Drop Stash"], destructive: 1 });
    if (choice === 1) await dropStash(projectID, root, entry);
  };
  return (
    <div className={styles.sheet} style={{ height: 400 }}>
      <div className={styles.sheetTitleRow}>
        <div><h2>Stashes</h2><small>Saved changes for this checkout</small></div>
        <BorderedButton disabled={!canStash} onClick={() => updateGit(root, { sheet: "newStash" })}>Stash Changes…</BorderedButton>
      </div>
      {git?.problem && <GitBanner problem={git.problem} dismiss={() => updateGit(root, { problem: undefined })} />}
      {!git?.stashes.length
        ? <div className={styles.unavailable}><Inbox size={28} strokeWidth={1.4} /><strong>No stashes</strong><small>Use Stash Changes to save unfinished edits.</small></div>
        : <div className={styles.stashList}>
            {git.stashes.map((entry) => (
              <div key={entry.commit} className={styles.stash}>
                <strong>{entry.message}</strong>
                <small>{stashReference(entry)} · {entry.branch ?? "detached HEAD"} · {relative(entry.date)}</small>
                <div className={styles.stashActions}>
                  <BorderedButton small disabled={!!git.activity} help="Restore these changes and their staging, and keep the stash" onClick={() => void applyStash(projectID, root, entry, false)}>Apply</BorderedButton>
                  <BorderedButton small disabled={!!git.activity} help="Restore these changes and their staging, then remove the stash" onClick={() => void applyStash(projectID, root, entry, true)}>Pop</BorderedButton>
                  <span className={styles.spacer} />
                  <BorderedButton small disabled={!!git.activity} className={styles.destructive} onClick={() => void drop(entry)}>Drop…</BorderedButton>
                </div>
              </div>
            ))}
          </div>}
      <div className={styles.sheetFooter}>
        <small>Apply keeps the stash. Pop removes it after a clean apply.</small>
        <span className={styles.spacer} />
        {git?.activity && <Spinner />}
        <PrimaryButton onClick={close}>Done</PrimaryButton>
      </div>
    </div>
  );
}

function relative(date: number): string {
  const seconds = (date - Date.now()) / 1000, format = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const units: [Intl.RelativeTimeFormatUnit, number][] = [["year", 31_536_000], ["month", 2_592_000], ["week", 604_800], ["day", 86_400], ["hour", 3_600], ["minute", 60]];
  for (const [unit, size] of units) if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
  return format.format(Math.round(seconds), "second");
}

function NewStash({ projectID, root, close }: { projectID: string; root: string; close: () => void }) {
  const branch = useReview((s) => s.checkouts[root]?.branch ?? "");
  const hasUntracked = useReview((s) => s.checkouts[root]?.files.some(isUntracked) ?? false);
  const git = useGit((s) => s.checkouts[root]);
  const [name, setName] = useState(branch ? `WIP on ${branch}` : "WIP");
  const [includeUntracked, setIncludeUntracked] = useState(true);
  const submit = async () => {
    const trimmed = name.trim();
    if (!trimmed || git?.activity) return;
    if (await stash(projectID, root, trimmed, includeUntracked && hasUntracked)) close();
  };
  return (
    <form className={styles.sheet} onSubmit={(e) => { e.preventDefault(); void submit(); }}>
      <div><h2>Stash Changes</h2><small>Save your edits under a name and clean the checkout.</small></div>
      <input autoFocus aria-label="Stash name" placeholder="Stash name" value={name} onChange={(e) => setName(e.target.value)} />
      <label className={styles.toggle}><input type="checkbox" disabled={!hasUntracked} checked={includeUntracked} onChange={(e) => setIncludeUntracked(e.target.checked)} />Include untracked files</label>
      <small>Staged and unstaged edits to tracked files are saved together with their staging. Untracked files stay on disk unless included.</small>
      {git?.problem && <GitBanner problem={git.problem} dismiss={() => updateGit(root, { problem: undefined })} />}
      <div className={styles.sheetFooter}>
        <span className={styles.spacer} />
        <BorderedButton onClick={close}>Cancel</BorderedButton>
        <PrimaryButton type="submit" disabled={!name.trim() || !!git?.activity}>Stash Changes</PrimaryButton>
      </div>
    </form>
  );
}

/**
 * Creates a pull request with the GitHub CLI after the branch is pushed. Unpushed commits must be
 * pushed explicitly first; this sheet never pushes as part of Create.
 */
function PullRequestSheet({ projectID, root, close }: { projectID: string; root: string; close: () => void }) {
  const status = useGit((s) => s.checkouts[root]?.status);
  const activity = useGit((s) => s.checkouts[root]?.activity);
  const [loading, setLoading] = useState(true), [available, setAvailable] = useState(true);
  const [existing, setExisting] = useState<PullRequest>();
  const [bases, setBases] = useState<string[]>([]), [base, setBase] = useState("");
  const [title, setTitle] = useState(""), [body, setBody] = useState(""), [draft, setDraft] = useState(true);
  const [working, setWorking] = useState(false), [failure, setFailure] = useState<string>();

  useEffect(() => {
    let active = true;
    void (async () => {
      try {
        const ghAvailable = await call("review", "pullRequestsAvailable");
        if (!active) return;
        setAvailable(ghAvailable);
        if (!ghAvailable) return;
        try { const found = await lookUpPullRequest(root); if (active) setExisting(found); if (found) return; }
        catch (error) { if (active) setFailure(`Couldn't look up pull requests: ${String(error instanceof Error ? error.message : error)}`); }
        const found = await baseBranches(root);
        if (!active) return;
        setBases(found.branches);
        const chosen = (found.defaultBranch && found.branches.includes(found.defaultBranch) ? found.defaultBranch : undefined)
          ?? found.branches.find((b) => b === "main" || b === "master") ?? found.branches[0] ?? "";
        setBase(chosen);
        if (chosen) {
          const suggestion = await pullRequestDraft(root, chosen);
          if (!active) return;
          setTitle((t) => t || suggestion.title); setBody((b) => b || suggestion.body);
        }
      } finally { if (active) setLoading(false); }
    })();
    return () => { active = false; };
  }, [root]);

  const pushBranch = async () => {
    setWorking(true);
    await push(projectID, root);
    setWorking(false);
    const problem = gitFor(root).pushProblem;
    setFailure(problem ? [problem.title, problem.hint, problem.detail].filter(Boolean).join("\n") : undefined);
  };
  const create = async () => {
    setWorking(true); setFailure(undefined);
    try { setExisting(await createPullRequest(root, title.trim(), body, base, draft)); }
    catch (error) { setFailure("Couldn't create the pull request. Your branch and commits are unchanged.\n\n" + String(error instanceof Error ? error.message : error)); }
    finally { setWorking(false); }
  };
  const notice = (icon: React.ReactNode, text: string) => <div className={styles.notice}>{icon}<span>{text}</span></div>;

  return (
    <form className={styles.sheet} onSubmit={(e) => { e.preventDefault(); if (!existing && !loading && available && !(status && canPush(status))) void create(); }}>
      <div><h2>{existing ? `Pull Request #${existing.number}` : "Create Pull Request"}</h2><small>GitHub · {status?.branch ?? ""}</small></div>
      {loading ? <div className={styles.unavailable} style={{ minHeight: 160 }}><Spinner /></div>
        : existing ? (
          <div className={styles.pullRequest}>
            <strong>{existing.title}</strong>
            <small>{existing.isDraft ? "Draft" : "Open"} · {status?.branch ?? ""} → {existing.baseRefName}</small>
            <BorderedButton onClick={() => run("app", "openExternal", existing.url)}><Compass size={13} />Open on GitHub</BorderedButton>
          </div>
        ) : !available ? notice(<TriangleAlert size={14} />, "Install the GitHub CLI (gh) and sign in with “gh auth login” to create pull requests from Octo.")
        : <>
            <div className={styles.baseRow}>
              <GitPullRequest size={14} />
              {bases.length
                ? <select aria-label="Base" value={base} onChange={(e) => setBase(e.target.value)}>{bases.map((b) => <option key={b}>{b}</option>)}</select>
                : <input aria-label="Base branch" placeholder="Base branch" value={base} onChange={(e) => setBase(e.target.value)} style={{ width: 160 }} />}
              <span className={styles.arrow}>←</span>
              <code>{status?.branch ?? ""}</code>
            </div>
            <input aria-label="Title" placeholder="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
            <label className={styles.descriptionField}>
              <span>Description</span>
              <textarea aria-label="Description" value={body} onChange={(e) => setBody(e.target.value)} />
            </label>
            <label className={styles.toggle}><input type="checkbox" checked={draft} onChange={(e) => setDraft(e.target.checked)} />Create as draft</label>
            {status && canPush(status)
              ? notice(<ArrowUpCircle size={14} />, publishes(status) && status.ahead === 0
                  ? `This branch isn't on ${pushRemote(status) ?? "the remote"} yet. Publish it before creating the pull request.`
                  : `${commits(status.ahead)} haven't been pushed. Push the branch before creating the pull request.`)
              : status && notice(<Info size={14} />, `Opens from ${status.upstream ?? status.branch ?? "this branch"} with its pushed commits. Uncommitted edits are excluded.`)}
          </>}
      {failure && <pre className={styles.failure}>{failure}</pre>}
      <div className={styles.sheetFooter}>
        <span className={styles.spacer} />
        {existing || loading || !available
          ? <PrimaryButton onClick={close}>Done</PrimaryButton>
          : <>
              <BorderedButton onClick={close}>Cancel</BorderedButton>
              {status && canPush(status)
                ? <PrimaryButton disabled={working || !!activity} onClick={() => void pushBranch()}><ArrowUp size={12} />{publishes(status) && status.ahead === 0 ? "Publish Branch" : "Push Branch"}</PrimaryButton>
                : <PrimaryButton type="submit" disabled={working || !title.trim() || !base}>{draft ? "Create Draft PR" : "Create PR"}</PrimaryButton>}
            </>}
      </div>
    </form>
  );
}
