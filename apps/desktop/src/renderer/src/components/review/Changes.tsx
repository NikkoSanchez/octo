import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Virtualizer } from "@pierre/diffs/react";
import { CircleCheck, Columns2, FileSearch, Minus, Plus, Undo2 } from "lucide-react";
import { hasStaged, hasWorking, isUntracked, supportsHunkStaging, type ChangedFile, type DiffStat } from "@octo/git/model";
import type { CodeAttachment, DiffScope, ReviewSnapshot } from "@octo/core";
import { preferredTarget } from "../../../../shared/openTargets";
import { useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { selectChange, setCodeSelection, setDiffLayout, showVisibleFile, useReview } from "../../state/review";
import { applyHunk, stage, unstage, updateGit } from "../../state/git";
import { attachToDraft, showPanel } from "../../lib/workspace";
import { contextMenu, type MenuSpec } from "../../lib/menu";
import { run } from "../../bridge";
import { CapsuleButton, cx, EmptyState, ToolbarButton } from "../controls";
import { ResizeHandle } from "../ResizeHandle";
import { CommitComposer } from "./CommitComposer";
import { CaptureBar } from "./CaptureBar";
import { DiffFile, WrapLinesButton } from "./Pierre";
import styles from "./review.module.css";

const ROW_HEIGHT = 44, GROUP_HEADER = 30;

/** Staged and Unstaged rows above the diff; the diff header follows the file at the top. */
export function Changes({ projectID, root, visible }: { projectID: string; root: string; visible: boolean }) {
  const review = useReview((s) => s.checkouts[root]);
  const layout = useReview((s) => s.diffLayout);
  const body = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(600);
  const [listHeight, setListHeight] = useState<number>();
  const dragStart = useRef(0);

  useLayoutEffect(() => {
    const node = body.current;
    if (!node) return;
    const observer = new ResizeObserver(() => setHeight(node.clientHeight));
    observer.observe(node);
    setHeight(node.clientHeight);
    return () => observer.disconnect();
  }, []);

  const files = review?.files ?? [];
  const staged = files.filter(hasStaged), unstaged = files.filter(hasWorking);
  // The list opens at its natural height up to 45% of the space; dragged, from one row to all rows above 160 px of diff.
  const natural = 2 * GROUP_HEADER + (staged.length + unstaged.length) * ROW_HEIGHT + 10;
  const initial = Math.max(0, Math.min(natural, height * 0.45));
  const upper = Math.max(initial, Math.min(natural, height - 160)), lower = Math.min(44, initial);
  const list = listHeight === undefined ? initial : Math.min(upper, Math.max(lower, listHeight));

  const current = review?.current;
  const split = layout === "sideBySide";
  const onSelection = useCallback((capture: CodeAttachment | undefined) => setCodeSelection(root, capture), [root]);

  return (
    <div className={styles.changes}>
      <div ref={body} className={styles.changesBody}>
        <div className={styles.changeList} data-testid="change-file-list" style={{ height: list }}>
          <ChangeGroup title="Staged" scope="staged" files={staged} stat={review?.stagedStat} actionTitle="Unstage All" projectID={projectID} root={root} />
          <ChangeGroup title="Unstaged" scope="working" files={unstaged} stat={review?.workingStat} actionTitle="Stage All" projectID={projectID} root={root} />
        </div>
        <ResizeHandle vertical label="Resize panels" value={list} style={{ left: 0, right: 0, top: list - 3.5 }}
          onDrag={(translation) => { if (translation === 0) dragStart.current = list; setListHeight(dragStart.current + translation); }}
          onStep={(delta) => setListHeight(list + delta)} />
        <div className={styles.diffArea} data-testid="change-diffs" style={{ top: list }}>
          {review?.error && <p className={styles.reviewError}>{review.error}</p>}
          {current ? <>
            <hr className={styles.hairline} />
            <DiffHeader snapshot={current} projectID={projectID} root={root} />
            <div className={styles.diffContent} inert={review.loadingSnapshot} style={{ opacity: review.loadingSnapshot ? 0.88 : 1 }}>
              {split
                ? current.notice && !current.lines.length
                  ? <p className={styles.diffNotice}>{current.notice}</p>
                  : <Virtualizer className={styles.diffScroller}><ChangeDiff snapshot={current} split projectID={projectID} root={root} onSelection={onSelection} /></Virtualizer>
                : <ContinuousDiff projectID={projectID} root={root} snapshots={review.changeSnapshots} onSelection={onSelection} visible={visible} />}
            </div>
            <hr className={styles.hairline} />
            <CaptureBar selection={review.selection} />
          </> : !review?.loadingSnapshot && (
            <EmptyState icon={files.length ? <FileSearch size={30} strokeWidth={1.4} /> : <CircleCheck size={30} strokeWidth={1.4} />} title={files.length ? "Choose a file" : "No changes"} />
          )}
        </div>
      </div>
      <CommitComposer projectID={projectID} root={root} stagedCount={staged.length} unstagedCount={unstaged.length} visible={visible} />
    </div>
  );
}

/** A Staged or Unstaged heading with its group action, then its rows. An empty group is just its heading. */
function ChangeGroup({ title, scope, files, stat, actionTitle, projectID, root }: {
  title: string; scope: DiffScope; files: ChangedFile[]; stat?: DiffStat; actionTitle: string; projectID: string; root: string;
}) {
  const selected = useReview((s) => s.checkouts[root]?.scope === scope ? s.checkouts[root]?.selectedPath : undefined);
  const toggle = (group: ChangedFile[]) => void (scope === "staged" ? unstage(projectID, root, group) : stage(projectID, root, group));
  return (
    <section aria-label={`${title}, ${files.length} files`}>
      <div className={styles.groupHeader}>
        <span className={styles.groupTitle}>{title}</span>
        <span className={styles.groupCount}>{files.length}</span>
        <span className={styles.spacer} />
        <button type="button" className={cx(styles.groupAction, files.length > 0 && styles.groupActionEnabled)} disabled={!files.length} onClick={() => toggle(files)}>{actionTitle}</button>
      </div>
      <div role="listbox" aria-label={title}>
        {files.map((file) => (
          <ChangedFileRow key={file.path} file={file} scope={scope} lines={stat?.files[file.path]} selected={selected === file.path}
            select={() => void selectChange(root, file, scope)} toggle={() => toggle([file])}
            menu={() => [
              { label: scope === "staged" ? "Unstage" : "Stage", action: () => toggle([file]) },
              ...(scope === "working" ? [{ label: "Discard Changes…", action: () => updateGit(root, { discardRequest: [file] }) }] : []),
              ...(file.worktreeStatus !== "D" && file.indexStatus !== "D"
                ? [{ type: "separator" as const }, { label: "Open File", action: () => showPanel({ type: "openFile", path: file.path, pinned: true }, true) }] : []),
            ]} />
        ))}
      </div>
    </section>
  );
}

/**
 * A changed file as a conversation-style row: status circle, name over folder, line counts in its
 * group's scope, and a visible stage (+) or unstage (−) control.
 */
function ChangedFileRow({ file, scope, lines, selected, select, toggle, menu }: {
  file: ChangedFile; scope: DiffScope; lines?: { additions: number; deletions: number }; selected: boolean;
  select: () => void; toggle: () => void; menu: () => MenuSpec[];
}) {
  const slash = file.path.lastIndexOf("/");
  const name = file.path.slice(slash + 1), folder = slash > 0 ? file.path.slice(0, slash) : "";
  const status = fileStatus(file, scope);
  const staged = scope === "staged";
  return (
    <div role="option" aria-selected={selected} tabIndex={0} title={file.path} className={cx(styles.fileRow, selected && styles.fileRowSelected)}
      onClick={select} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); select(); } }} onContextMenu={contextMenu(menu)}>
      <span className={styles.status} style={{ "--status": status.color } as React.CSSProperties} title={status.label}>{status.letter}</span>
      <span className={styles.fileText}>
        <strong>{name}</strong>
        {folder && <small>{folder}</small>}
      </span>
      {lines && (
        <span className={styles.lineCounts} aria-label={`${lines.additions} lines added, ${lines.deletions} removed`}>
          <span className={styles.added}>+{lines.additions}</span><span className={styles.removed}>−{lines.deletions}</span>
        </span>
      )}
      <ToolbarButton aria-label={`${staged ? "Unstage" : "Stage"} ${name}`} help={`${staged ? "Unstage" : "Stage"} ${name}`}
        onClick={(e) => { e.stopPropagation(); toggle(); }}>{staged ? <Minus size={12} strokeWidth={2.5} /> : <Plus size={12} strokeWidth={2.5} />}</ToolbarButton>
    </div>
  );
}

function fileStatus(file: ChangedFile, scope: DiffScope): { letter: string; label: string; color: string } {
  if (scope === "staged") {
    switch (file.indexStatus) {
      case "A": return { letter: "A", label: "Staged · Added", color: "var(--green)" };
      case "D": return { letter: "D", label: "Staged · Deleted", color: "var(--red)" };
      case "R": return { letter: "R", label: `Staged · Renamed from ${file.originalPath ?? "another path"}`, color: "var(--blue)" };
      case "C": return { letter: "C", label: "Staged · Copied", color: "var(--blue)" };
      default: return { letter: "M", label: "Staged · Modified", color: "var(--blue)" };
    }
  }
  if (isUntracked(file)) return { letter: "U", label: "Untracked", color: "var(--green)" };
  if (file.worktreeStatus === "D") return { letter: "D", label: "Deleted", color: "var(--red)" };
  return { letter: "M", label: "Modified", color: "var(--yellow)" };
}

/** The current file's path, scope, layout toggle and actions: discard (unstaged only), stage or unstage, Open in. */
function DiffHeader({ snapshot, projectID, root }: { snapshot: ReviewSnapshot; projectID: string; root: string }) {
  const file = useReview((s) => s.checkouts[root]?.files.find((f) => f.path === snapshot.path));
  const selection = useReview((s) => s.checkouts[root]?.selection);
  const split = useReview((s) => s.diffLayout === "sideBySide");
  const target = preferredTarget(useApp((s) => s.openTarget));
  const staged = snapshot.scope === "staged";
  return (
    <div className={styles.surfaceHeader}>
      <div className={styles.surfaceTitle}>
        <strong title={snapshot.path}><bdi>{snapshot.path}</bdi></strong>
        <small>{staged ? "Staged · HEAD → Index" : "Unstaged · Index → Working tree"}</small>
      </div>
      <ToolbarButton aria-label="Side-by-side diff" aria-pressed={split} active={split} help={split ? "Show stacked diff" : "Show side-by-side diff"}
        onClick={() => setDiffLayout(split ? "stacked" : "sideBySide")}><Columns2 size={15} /></ToolbarButton>
      <WrapLinesButton />
      {file && <>
        {!staged && (
          <ToolbarButton aria-label="Discard unstaged changes" help={`Discard unstaged changes to ${snapshot.path}…`} onClick={() => updateGit(root, { discardRequest: [file] })}><Undo2 size={14} /></ToolbarButton>
        )}
        <CapsuleButton help={staged ? "Move this file's staged changes back to Unstaged" : "Stage this file for the next commit"}
          onClick={() => void (staged ? unstage(projectID, root, [file]) : stage(projectID, root, [file]))}>{staged ? "Unstage File" : "Stage File"}</CapsuleButton>
      </>}
      <CapsuleButton help={target.kind === "app" && ["terminal", "ghostty", "iterm", "warp"].includes(target.id) ? `Open this checkout in ${target.title} (⇧⌘E)` : `Open ${snapshot.path} in ${target.title} (⇧⌘E)`}
        onClick={() => run("app", "openTarget", target.id, { projectID, checkout: root, path: snapshot.path, line: selection?.newLines?.[0] ?? 1 })}>
        Open in {target.title}
      </CapsuleButton>
    </div>
  );
}

/** Every change in one scrolling document. The header above follows the file at the top. */
function ContinuousDiff({ projectID, root, snapshots, onSelection, visible }: {
  projectID: string; root: string; snapshots: ReviewSnapshot[]; onSelection: (capture: CodeAttachment | undefined) => void; visible: boolean;
}) {
  const frame = useRef<HTMLDivElement>(null);
  const reveal = useReview((s) => s.checkouts[root]?.reveal);
  const focus = useUI((s) => s.reviewFocus);

  useEffect(() => {
    if (!reveal) return;
    frame.current?.querySelector(`[data-diff-index="${reveal.index}"]`)?.scrollIntoView({ block: "start" });
  }, [reveal]);
  // ⌘4 focuses the diff only while it shows.
  const shown = useRef(visible);
  shown.current = visible;
  useEffect(() => { if (shown.current && focus) frame.current?.querySelector<HTMLElement>("[data-diff-index]")?.focus(); }, [focus]);
  useEffect(() => {
    const node = frame.current;
    if (!node) return;
    let pending = 0;
    const scrolled = (event: Event) => {
      const scroller = event.target as HTMLElement;
      if (pending || !(scroller instanceof HTMLElement)) return;
      pending = requestAnimationFrame(() => {
        pending = 0;
        const top = scroller.getBoundingClientRect().top + 1;
        const sections = [...node.querySelectorAll<HTMLElement>("[data-diff-index]")];
        const first = sections.find((section) => section.getBoundingClientRect().bottom > top);
        if (first) showVisibleFile(root, Number(first.dataset.diffIndex));
      });
    };
    node.addEventListener("scroll", scrolled, true);
    return () => { node.removeEventListener("scroll", scrolled, true); cancelAnimationFrame(pending); };
  }, [root]);

  return (
    <div ref={frame} className={styles.diffFrame}>
      <Virtualizer className={styles.diffScroller}>
        {snapshots.map((snapshot, index) => (
          <section key={`${snapshot.scope}:${snapshot.path}`} data-diff-index={index} tabIndex={-1} className={styles.diffSection}>
            <div className={styles.fileLabel}><strong>{snapshot.path}</strong><span>· {snapshot.scope === "staged" ? "Staged" : "Unstaged"}</span></div>
            {snapshot.notice && !snapshot.lines.length
              ? <p className={styles.diffNotice}>{snapshot.notice}</p>
              : <ChangeDiff snapshot={snapshot} split={false} projectID={projectID} root={root} onSelection={onSelection} />}
          </section>
        ))}
      </Virtualizer>
    </div>
  );
}

/** One file's diff with hunk staging for ordinary modifications in its scope. */
function ChangeDiff({ snapshot, split, projectID, root, onSelection }: {
  snapshot: ReviewSnapshot; split: boolean; projectID: string; root: string; onSelection: (capture: CodeAttachment | undefined) => void;
}) {
  const file = useReview((s) => s.checkouts[root]?.files.find((f) => f.path === snapshot.path));
  const hunks = !snapshot.notice && file && supportsHunkStaging(file, snapshot.scope);
  const onHunk = useCallback((hunk: number) => void applyHunk(projectID, root, snapshot, hunk), [projectID, root, snapshot]);
  return (
    <DiffFile snapshot={snapshot} split={split} hunkTitle={hunks ? (snapshot.scope === "staged" ? "Unstage Hunk" : "Stage Hunk") : undefined}
      onHunk={hunks ? onHunk : undefined} onSelection={onSelection} onAttach={attachToDraft} />
  );
}
