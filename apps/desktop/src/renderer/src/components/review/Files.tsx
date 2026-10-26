import { memo, useEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, ChevronRight, FilePlus, FileQuestion, FileSearch, FileText, Folder, PanelLeft, RotateCw } from "lucide-react";
import { panelFiles, type PanelTabs } from "@octo/core";
import { preferredTarget } from "../../../../shared/openTargets";
import { useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { useReview } from "../../state/review";
import { refreshCheckout } from "../../state/git";
import { checkFiles, fileKey, openFile, useFiles } from "../../state/files";
import { fileTree, type FileNode } from "../../lib/fileTree";
import { closePanelTab, requestFileAction, showPanel } from "../../lib/workspace";
import { contextMenu } from "../../lib/menu";
import { run } from "../../bridge";
import { BorderedButton, CapsuleButton, cx, EmptyState, Spinner, ToolbarButton } from "../controls";
import { ResizeHandle } from "../ResizeHandle";
import { CaptureBar } from "./CaptureBar";
import { FileEditor } from "./FileEditor";
import { WrapLinesButton } from "./Pierre";
import styles from "./review.module.css";

/** Files' row above the tree and editor: the tree toggle, then new file and refresh. */
export function FilesControls({ projectID, root, showsTree }: { projectID: string; root: string; showsTree: boolean }) {
  const loading = useReview((s) => s.checkouts[root]?.loading);
  return (
    <div className={styles.filesControls}>
      <ToolbarButton aria-label={showsTree ? "Hide file tree" : "Show file tree"} help={showsTree ? "Hide file tree" : "Show file tree"} active={showsTree}
        onClick={() => run("store", "updatePanelTabsAction", projectID, { type: "setFileTree", visible: !showsTree })}><PanelLeft size={15} /></ToolbarButton>
      <span className={styles.spacer} />
      {loading && <Spinner />}
      <ToolbarButton aria-label="New file" help="New file" onClick={() => requestFileAction("create", "")}><FilePlus size={15} /></ToolbarButton>
      <ToolbarButton aria-label="Refresh changes" help="Refresh changes (⇧⌘R)" onClick={() => { void refreshCheckout(projectID, root); void checkFiles(); }}><RotateCw size={14} /></ToolbarButton>
    </div>
  );
}

/** The file tree beside the editor. Every open file tab keeps its editor, with its undo history, mounted. */
export function Files({ projectID, root, tabs, visible }: { projectID: string; root: string; tabs: PanelTabs; visible: boolean }) {
  const paths = useReview((s) => s.checkouts[root]?.paths);
  const loaded = useReview((s) => !!s.checkouts[root] && !s.checkouts[root]!.loading);
  const selection = useReview((s) => s.checkouts[root]?.fileSelection);
  const [treeWidth, setTreeWidth] = useState<number>();
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  const dragStart = useRef(0);
  const selected = tabs.selected?.kind === "file" ? tabs.selected.path : undefined;
  const open = panelFiles(tabs);
  const [failed, setFailed] = useState<Record<string, string>>({});

  useEffect(() => {
    const node = box.current;
    if (!node) return;
    const observer = new ResizeObserver(() => setWidth(node.clientWidth));
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  useEffect(() => { if (visible) void checkFiles(); }, [visible]);
  useEffect(() => {
    if (!selected) return;
    let active = true;
    void openFile(root, selected).then(() => { if (active) setFailed((f) => { const next = { ...f }; delete next[selected]; return next; }); })
      .catch((error) => { if (active) setFailed((f) => ({ ...f, [selected]: String(error instanceof Error ? error.message : error) })); });
    return () => { active = false; };
  }, [root, selected]);

  // The tree starts at 30% of the card, between 150 and 260 px, leaving the editor at least 270.
  const available = Math.max(0, width - 7);
  const upper = Math.min(260, Math.max(0, available - 270)), lower = Math.min(150, upper);
  const tree = Math.min(upper, Math.max(lower, treeWidth ?? available * 0.3));
  const showsTree = tabs.showsFileTree;
  const session = useFiles((s) => selected ? s.sessions[fileKey(root, selected)] : undefined);

  return (
    <div ref={box} className={styles.files}>
      {showsTree && <>
        <div className={styles.treeColumn} style={{ width: tree }}>
          <FileTree root={root} paths={paths ?? []} selected={selected} />
        </div>
        <ResizeHandle label="Resize panels" value={tree} idleLine style={{ left: tree, top: 0, bottom: 0 }}
          onDrag={(translation) => { if (translation === 0) dragStart.current = tree; setTreeWidth(dragStart.current + translation); }}
          onStep={(delta) => setTreeWidth(tree + delta)} />
      </>}
      <div className={styles.editorColumn} style={{ left: showsTree ? tree + 7 : 0 }}>
        {selected && session ? <>
          <hr className={styles.hairline} />
          <FileHeader projectID={projectID} root={root} path={selected} />
        </> : null}
        <div className={styles.editors}>
          {open.map((path) => (
            <div key={path} className={styles.editorSlot} inert={path !== selected} aria-hidden={path !== selected} style={{ visibility: path === selected ? undefined : "hidden" }}>
              <FileEditor root={root} path={path} projectID={projectID} visible={visible && path === selected} />
            </div>
          ))}
          {selected && failed[selected] && !session && loaded && (
            <EmptyState icon={<FileQuestion size={30} strokeWidth={1.4} />} title="File not found" description={`${selected} is not in this checkout.`}>
              <BorderedButton onClick={() => closePanelTab({ kind: "file", path: selected })}>Close Tab</BorderedButton>
            </EmptyState>
          )}
          {!selected && <EmptyState icon={<FileSearch size={30} strokeWidth={1.4} />} title="Choose a file" />}
        </div>
        {selected && session && <><hr className={styles.hairline} /><CaptureBar selection={selection} /></>}
      </div>
    </div>
  );
}

function FileHeader({ projectID, root, path }: { projectID: string; root: string; path: string }) {
  const target = preferredTarget(useApp((s) => s.openTarget));
  const selection = useReview((s) => s.checkouts[root]?.fileSelection);
  return (
    <div className={styles.surfaceHeader}>
      <div className={styles.surfaceTitle}><strong title={path}><bdi>{path}</bdi></strong></div>
      <WrapLinesButton />
      <CapsuleButton help={`Open ${path} in ${target.title} (⇧⌘E)`}
        onClick={() => run("app", "openTarget", target.id, { projectID, checkout: root, path, line: selection?.newLines?.[0] ?? 1 })}>Open in {target.title}</CapsuleButton>
    </div>
  );
}

/**
 * Folders expand in place. A single click opens a replaceable preview tab; double-clicking or
 * Open File keeps the tab. A file revealed from a link or ⌘P expands its folders.
 */
const FileTree = memo(function FileTree({ root, paths, selected }: { root: string; paths: string[]; selected?: string }) {
  const nodes = useMemo(() => fileTree(paths), [paths]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const list = useRef<HTMLDivElement>(null);
  const reveal = useUI((s) => s.reviewLocation);
  useEffect(() => { setExpanded(new Set()); }, [root]);
  useEffect(() => {
    if (!selected) return;
    const parts = selected.split("/");
    setExpanded((current) => {
      const next = new Set(current);
      for (let i = 1; i < parts.length; i++) next.add(parts.slice(0, i).join("/"));
      return next.size === current.size ? current : next;
    });
    requestAnimationFrame(() => list.current?.querySelector(`[data-path="${CSS.escape(selected)}"]`)?.scrollIntoView({ block: "nearest" }));
  }, [selected, reveal?.request]);

  const open = (path: string, pinned: boolean) => showPanel({ type: "openFile", path, pinned }, pinned);
  const folderOf = (path: string) => path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "";
  const rows = (items: FileNode[], depth: number): React.ReactNode => items.map((node) => node.directory ? (
    <div key={`d:${node.path}`}>
      <button type="button" className={styles.treeRow} style={{ paddingLeft: 8 + depth * 14 }} aria-expanded={expanded.has(node.path)}
        onClick={() => setExpanded((current) => { const next = new Set(current); if (next.has(node.path)) next.delete(node.path); else next.add(node.path); return next; })}
        onContextMenu={contextMenu(() => [{ label: "New File Here…", action: () => requestFileAction("create", node.path + "/") }])}>
        {expanded.has(node.path) ? <ChevronDown size={10} strokeWidth={2.5} /> : <ChevronRight size={10} strokeWidth={2.5} />}
        <Folder size={14} /><span>{node.name}</span>
      </button>
      {expanded.has(node.path) && rows(node.children, depth + 1)}
    </div>
  ) : (
    <button key={`f:${node.path}`} type="button" data-path={node.path} title={node.path} className={cx(styles.treeRow, selected === node.path && styles.treeSelected)}
      style={{ paddingLeft: 22 + depth * 14 }} onClick={() => open(node.path, false)} onDoubleClick={() => open(node.path, true)}
      onContextMenu={contextMenu(() => [
        { label: "Open File", action: () => open(node.path, true) },
        { label: "New File Here…", action: () => requestFileAction("create", folderOf(node.path)) },
        { type: "separator" },
        { label: "Delete File…", action: () => requestFileAction("delete", node.path) },
      ])}>
      <FileText size={14} /><span>{node.name}</span>
    </button>
  ));
  return <div ref={list} className={styles.tree} role="tree" aria-label="Files">{rows(nodes, 0)}</div>;
});
