import { useEffect, useRef, useState } from "react";
import { ChevronDown, Folder, Search, SquareTerminal } from "lucide-react";
import { preferredTarget, targetSymbol, type AvailableTarget } from "../../../../shared/openTargets";
import { checkoutRoot, selectedProject, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { useReview } from "../../state/review";
import { refreshCheckout } from "../../state/git";
import { showPanel } from "../../lib/workspace";
import { popup } from "../../lib/menu";
import { call, run } from "../../bridge";
import { cx, HoverButton, Spinner } from "../controls";
import { ChangesIcon, GitBranchIcon } from "../icons";
import { Popover } from "../Popover";
import styles from "./projectActions.module.css";

/**
 * Shown while the review panel is hidden, as in T3 Code and Codex: open the checkout elsewhere,
 * switch local branches and jump to Changes. It floats beside the chat when the margin fits it,
 * otherwise it opens from the titlebar capsule.
 */
export function ProjectActions({ floating }: { floating: boolean }) {
  const info = useApp((s) => {
    const project = selectedProject(s), root = checkoutRoot(s);
    return {
      projectID: project?.id, root, openTarget: s.openTarget,
      // An agent working in this checkout could be writing files; switching under it is unsafe.
      agentRunning: !!project?.threads.some((t) => s.running.includes(t.id) && t.workingDirectory === root),
    };
  });
  const review = useReview((s) => info.root ? s.checkouts[info.root] : undefined);
  const [targets, setTargets] = useState<AvailableTarget[]>([]);
  const [choosingBranch, setChoosingBranch] = useState(false);
  const branchButton = useRef<HTMLButtonElement>(null);

  // Apps may be installed or removed while Octo runs.
  useEffect(() => {
    let active = true;
    void call("app", "openTargets").then((list) => { if (active) setTargets(list); }).catch(() => {});
    return () => { active = false; };
  }, []);

  if (!info.projectID || !info.root) return null;
  const { projectID, root } = info;
  const target = targets.find((t) => t.id === info.openTarget) ?? targets[0] ?? preferredTarget(info.openTarget);
  const open = (chosen: AvailableTarget) => {
    run("store", "setOpenTarget", chosen.id);
    useUI.setState({ projectActions: false });
    run("app", "openTarget", chosen.id, { projectID, checkout: root });
  };
  const branch = review?.branch ?? "";
  const stat = review?.diffStat, changeCount = review?.files.length ?? 0;

  return (
    <div className={cx(styles.card, floating && styles.floating)} role={floating ? "region" : undefined} aria-label="Project actions" data-testid="project-card">
      <div className={styles.checkout} title={root.replace(/^\/Users\/[^/]+/, "~")}>
        <Folder size={14} /><span>{root.split("/").filter(Boolean).at(-1)}</span>
      </div>
      <div className={styles.splitRow}>
        <HoverButton className={styles.row} help={`Open this checkout in ${target.title}`} onClick={() => open(target)}>
          {target.icon ? <img src={target.icon} alt="" width={16} height={16} /> : <SquareTerminal size={15} />}
          <span>Open in {target.title}</span>
        </HoverButton>
        <i className={styles.splitDivider} />
        <HoverButton padded={false} className={styles.chevron} aria-label="Choose where to open" help="Choose where to open"
          onClick={(e) => void popup(targets.map((t) => ({ label: t.title, icon: t.icon, symbol: targetSymbol(t), checked: t.id === target.id, action: () => open(t) })), e.currentTarget)}>
          <ChevronDown size={11} strokeWidth={2.5} />
        </HoverButton>
      </div>
      <hr className={styles.divider} />
      <HoverButton ref={branchButton} className={styles.row} help="Switch branch" aria-label={`Branch ${branch}. Switch branch`} aria-expanded={choosingBranch}
        onClick={() => setChoosingBranch((v) => !v)}>
        <GitBranchIcon size={15} /><span>{branch || "No branch"}</span><ChevronDown size={11} strokeWidth={2.5} className={styles.trailing} />
      </HoverButton>
      <HoverButton className={styles.row} help="Show changes in the review panel" aria-label="Show changes"
        onClick={() => { useUI.setState({ projectActions: false }); showPanel({ type: "showChanges" }); }}>
        <ChangesIcon size={14} /><span>Changes</span>
        <span className={styles.trailing}>
          {stat ? <><b className={styles.added}>+{stat.additions}</b> <b className={styles.removed}>−{stat.deletions}</b></>
            : changeCount > 0 ? <b className={styles.count}>{changeCount} files</b> : null}
        </span>
      </HoverButton>
      {choosingBranch && (
        <Popover anchor={branchButton} label="Switch branch" width={280} close={() => setChoosingBranch(false)}>
          <BranchPicker current={branch} root={root} projectID={projectID} agentRunning={info.agentRunning} dismiss={() => setChoosingBranch(false)} />
        </Popover>
      )}
    </div>
  );
}

/** Searchable local branches. Arrow keys move the highlight; Return switches. */
function BranchPicker({ current, root, projectID, agentRunning, dismiss }: {
  current: string; root: string; projectID: string; agentRunning: boolean; dismiss: () => void;
}) {
  const [branches, setBranches] = useState<string[]>();
  const [query, setQuery] = useState(""), [highlighted, setHighlighted] = useState(0);
  const [switching, setSwitching] = useState<string>(), [error, setError] = useState<string>();
  const list = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let active = true;
    void call("review", "branches", root).then((found) => { if (active) setBranches(found); });
    return () => { active = false; };
  }, [root]);

  const filtered = (branches ?? []).filter((b) => b.toLowerCase().includes(query.toLowerCase()));
  // The checked-out branch leads, like the other recent branches it is sorted with.
  const matches = [...filtered.filter((b) => b === current), ...filtered.filter((b) => b !== current)];

  useEffect(() => { list.current?.querySelector(`[data-index="${highlighted}"]`)?.scrollIntoView({ block: "nearest" }); }, [highlighted]);

  const choose = async (name: string) => {
    if (name === current) { dismiss(); return; }
    if (agentRunning || switching) return;
    setSwitching(name); setError(undefined);
    try {
      await call("review", "switchBranch", name, root);
      await refreshCheckout(projectID, root);
      dismiss();
    } catch (failure) {
      setError(String(failure instanceof Error ? failure.message : failure).trim());
    } finally { setSwitching(undefined); }
  };

  return (
    <div className={styles.picker}>
      <label className={styles.search}>
        <Search size={13} />
        <input autoFocus data-plain aria-label="Search branches" placeholder="Search branches…" value={query}
          onChange={(e) => { setQuery(e.target.value); setHighlighted(0); }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") { e.preventDefault(); setHighlighted((i) => Math.min(i + 1, Math.max(0, matches.length - 1))); }
            else if (e.key === "ArrowUp") { e.preventDefault(); setHighlighted((i) => Math.max(i - 1, 0)); }
            else if (e.key === "Enter" && matches[highlighted]) { e.preventDefault(); void choose(matches[highlighted]); }
          }} />
      </label>
      <hr className={styles.divider} />
      {agentRunning && <p className={styles.note}>Stop the agent working in this checkout before switching branches.</p>}
      {error && <p className={cx(styles.note, styles.error)}>{error}</p>}
      <div ref={list} className={styles.branches} role="listbox" aria-label="Branches">
        {!matches.length && <p className={styles.note}>{branches === undefined || branches.length === 0 ? "Loading branches…" : "No matching branches"}</p>}
        {matches.map((name, index) => (
          <HoverButton key={name} data-index={index} role="option" aria-selected={index === highlighted} selected={index === highlighted}
            className={styles.branch} disabled={!!switching || (agentRunning && name !== current)} onClick={() => void choose(name)}>
            <span>{name}</span>
            {name === current && <small>current</small>}
            {switching === name && <Spinner />}
          </HoverButton>
        ))}
      </div>
    </div>
  );
}
