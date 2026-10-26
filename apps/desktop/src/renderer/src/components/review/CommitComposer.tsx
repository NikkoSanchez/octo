import { useEffect, useRef, useState } from "react";
import { ArrowUp, Check, CircleCheck, CirclePlus, GitPullRequest, Sparkles } from "lucide-react";
import { harnessTitle, type HarnessID } from "@octo/core";
import type { CommitMessageModel } from "@octo/agents/model";
import { canPush, publishes, pushRemote } from "@octo/git/model";
import { useApp } from "../../state/app";
import { cancelDraft, commit, commits, draftMessage, filesLabel, pullRequestFor, push, updateGit, useGit } from "../../state/git";
import { popup, type MenuSpec } from "../../lib/menu";
import { call, run } from "../../bridge";
import { CapsuleButton, PrimaryButton, Spinner } from "../controls";
import { providerMenuIcon } from "../ProviderIcon";
import styles from "./review.module.css";

/** Commits only what is staged. After a commit, the next explicit step (Push or Create PR) appears. */
export function CommitComposer({ projectID, root, stagedCount, unstagedCount, visible }: {
  projectID: string; root: string; stagedCount: number; unstagedCount: number; visible: boolean;
}) {
  const git = useGit((s) => s.checkouts[root]);
  // Hiding the Changes surface retires a commit message being written for it.
  useEffect(() => { if (!visible) cancelDraft(root); }, [visible, root]);
  const last = stagedCount === 0 ? git?.lastCommit : undefined;
  if (!last && stagedCount + unstagedCount === 0) return null;
  return (
    <div className={styles.commit} data-testid="commit-composer">
      {last ? <Committed projectID={projectID} root={root} unstagedCount={unstagedCount} hash={last.hash} subject={last.subject} />
        : stagedCount > 0 ? <Compose projectID={projectID} root={root} stagedCount={stagedCount} unstagedCount={unstagedCount} />
        // Collapsed until there is something to commit; a typed draft is kept.
        : <div className={styles.stageHint}><CirclePlus size={13} /><span>Stage files or hunks to commit them</span><span className={styles.spacer} />{git?.draft && <span>Draft kept</span>}</div>}
    </div>
  );
}

/** The commit message model menu's inputs. */
function useCommitChoices(root: string) {
  const choices = useApp((s) => ({
    selection: s.commitMessageModel, descriptors: s.descriptors, catalogs: s.modelCatalogs, loading: s.loadingModels, errors: s.modelErrors,
  }));
  const [automatic, setAutomatic] = useState<CommitMessageModel[]>([]);
  useEffect(() => {
    run("store", "loadCommitMessageModels", root);
    let active = true;
    void call("store", "automaticCommitModels", root).then((models) => { if (active) setAutomatic(models); }).catch(() => {});
    return () => { active = false; };
  }, [root, choices.descriptors, choices.catalogs]);
  const candidates = choices.selection ? [choices.selection] : automatic;
  /** The catalog's name, or the CLI alias when no catalog has loaded. */
  const name = (model: CommitMessageModel) => choices.catalogs[`${model.harness}:${root}`]?.find((m) => m.model === model.model)?.displayName
    ?? (model.model.includes("-") ? model.model : model.model.charAt(0).toUpperCase() + model.model.slice(1));
  return { ...choices, automatic, candidates, name };
}

function Compose({ projectID, root, stagedCount, unstagedCount }: { projectID: string; root: string; stagedCount: number; unstagedCount: number }) {
  const git = useGit((s) => s.checkouts[root]);
  const choices = useCommitChoices(root);
  const editor = useRef<HTMLTextAreaElement>(null);
  const message = git?.draft ?? "";
  const drafting = git?.drafting;
  const canCommit = stagedCount > 0 && !!message.trim() && !git?.activity && !drafting;
  const next = choices.candidates[0];

  /** Sends only the staged diff, and only on click. While writing, the same button stops. */
  const generate = async () => {
    if (drafting) { cancelDraft(root); return; }
    const text = await draftMessage(root, choices.candidates);
    if (text === undefined) return;
    // One undoable edit replaces the message, so ⌘Z brings back the text it replaced.
    const node = editor.current;
    if (node) { node.focus(); node.select(); if (!document.execCommand("insertText", false, text)) updateGit(root, { draft: text }); }
    else updateGit(root, { draft: text });
  };
  const modelMenu = (anchor: Element) => {
    const dark = document.documentElement.dataset.dark === "true";
    const items: MenuSpec[] = [
      { type: "header", label: "Write commit messages with" },
      { label: "Automatic" + (choices.automatic[0] ? ` · ${choices.name(choices.automatic[0])}` : ""), checked: !choices.selection,
        toolTip: "Claude's Haiku when the Claude CLI is installed, otherwise Codex's newest Luna", action: () => run("store", "selectCommitMessageModel", undefined) },
      { type: "separator" },
      ...choices.descriptors.map((provider): MenuSpec => {
        const id = provider.id as HarnessID, key = `${id}:${root}`, models = (choices.catalogs[key] ?? []).filter((m) => !m.hidden), installed = !!provider.executable;
        return {
          type: "submenu", label: harnessTitle(id) + (installed ? "" : " · not installed"), icon: providerMenuIcon(id, dark),
          items: models.length
            ? models.map((model) => ({ label: model.displayName, toolTip: model.description, enabled: installed,
                checked: choices.selection?.harness === id && choices.selection.model === model.model,
                action: () => run("store", "selectCommitMessageModel", { harness: id, model: model.model }) }))
            : [{ type: "header", label: choices.loading.includes(key) ? "Loading models…" : installed ? choices.errors[key] ?? "No models reported" : "Not installed" }],
        };
      }),
    ];
    void popup(items, anchor);
  };

  return <>
    <div className={styles.commitHeader}>
      <strong>Commit staged changes</strong>
      <span className={styles.spacer} />
      <CapsuleButton disabled={!drafting && (!next || !!git?.activity)} onClick={() => void generate()}
        help={drafting ? "Stop writing the commit message"
          : next ? `Write a message for the staged changes with ${choices.name(next)}. Sends the staged diff through the ${harnessTitle(next.harness)} CLI.`
          : "Install the Claude or Codex CLI to write commit messages"}>
        {drafting ? <><Spinner />Stop</> : <><Sparkles size={11} />Generate</>}
      </CapsuleButton>
      <button type="button" className={styles.modelMenu} disabled={!!drafting} aria-label="Commit message model" title="Choose the model that writes commit messages"
        onClick={(e) => modelMenu(e.currentTarget)}>{next ? choices.name(next) : "No model"}</button>
    </div>
    <div className={styles.commitField}>
      <textarea ref={editor} aria-label="Commit message" value={message} readOnly={!!drafting} style={{ opacity: drafting ? 0.5 : 1 }}
        placeholder={drafting ? `Writing with ${choices.name(drafting)}…` : "Describe the staged changes…"}
        onChange={(e) => updateGit(root, { draft: e.target.value })} />
    </div>
    <div className={styles.commitFooter}>
      <span>{filesLabel(stagedCount)} staged{unstagedCount > 0 ? ` · ${unstagedCount} unstaged not included` : ""}</span>
      <span className={styles.spacer} />
      <PrimaryButton pill small disabled={!canCommit} help={stagedCount === 0 ? "Stage a file or hunk to commit it" : "Commit the staged changes only"}
        onClick={() => { if (canCommit) void commit(projectID, root, message); }}><Check size={12} strokeWidth={3} />Commit</PrimaryButton>
    </div>
  </>;
}

function Committed({ projectID, root, unstagedCount, hash, subject }: { projectID: string; root: string; unstagedCount: number; hash: string; subject: string }) {
  const git = useGit((s) => s.checkouts[root]);
  const status = git?.status, request = git && pullRequestFor(git);
  const unpushed = !!status && canPush(status);
  return (
    <div className={styles.committed}>
      <CircleCheck size={17} className={styles.committedIcon} />
      <div className={styles.committedText}>
        <strong>{request ? "Pull request open" : unpushed ? "Committed locally" : "Branch pushed"}</strong>
        <small>{hash} · {subject}</small>
        <small>{unstagedCount > 0 ? `${filesLabel(unstagedCount)} unstaged, kept on disk.` : "All staged changes committed."}</small>
      </div>
      {unpushed
        ? <PrimaryButton pill small disabled={!!git?.activity} onClick={() => void push(projectID, root)}><ArrowUp size={12} />{publishes(status!) && status!.ahead === 0 ? "Publish" : `Push ${commits(status!.ahead)}`}</PrimaryButton>
        : <PrimaryButton pill small disabled={!status || !pushRemote(status)} onClick={() => updateGit(root, { sheet: "pullRequest" })}><GitPullRequest size={12} />{request ? `View PR #${request.number}` : "Create PR"}</PrimaryButton>}
    </div>
  );
}
