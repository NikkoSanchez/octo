import { useEffect, useRef } from "react";
import { ChevronDown, EyeOff, Files as FilesIcon, FileText, Globe, Plus, X } from "lucide-react";
import { isPrivateBrowser, panelBrowsers, tabKey, tabsEqual, type PanelTab, type PanelTabs } from "@octo/core";
import { checkoutRoot, selectedProject, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { useReview } from "../../state/review";
import { browserTitle, useBrowsers } from "../../state/browser";
import { closePanelTab, openBrowserTab, showPanel } from "../../lib/workspace";
import { contextMenu, popup } from "../../lib/menu";
import { run } from "../../bridge";
import { cx } from "../controls";
import { ChangesIcon } from "../icons";
import { Changes } from "./Changes";
import { Files, FilesControls } from "./Files";
import { GitHeader } from "./GitHeader";
import { BrowserPane } from "./BrowserPane";
import { Editors } from "./Pierre";
import styles from "./review.module.css";

/**
 * The project's review card: a segmented capsule of tabs over Changes, Files and browser pages.
 * Every open surface stays mounted, so diffs, editors (with undo) and pages survive switching tabs.
 */
export default function ReviewPanel({ visible }: { visible: boolean }) {
  const info = useApp((s) => {
    const project = selectedProject(s);
    return { projectID: project?.id, tabs: project?.panelTabs, root: checkoutRoot(s) };
  });
  if (!info.projectID || !info.tabs || !info.root) return null;
  const { projectID, tabs, root } = info;
  const selected = tabs.selected;
  const browsingFiles = selected?.kind === "files" || selected?.kind === "file";
  const browser = selected?.kind === "browser" ? selected.id : undefined;

  return (
    <Editors>
      <div className={styles.panel} data-testid="review-panel">
        <div className={styles.tabRow}>
          <TabStrip tabs={tabs} />
          <button type="button" className={styles.addSurface} aria-label="Open a surface" title="Open a browser, files or changes"
            onClick={(e) => void popup([
              { label: "Browser", action: () => openBrowserTab() },
              { label: "Private Browser", action: () => openBrowserTab(true) },
              { label: "Files", action: () => showPanel({ type: "showFiles" }) },
              { label: "Changes", action: () => showPanel({ type: "showChanges" }) },
            ], e.currentTarget)}>
            <Plus size={14} />
          </button>
        </div>
        {/* The second row: branch and Git actions for Changes, file actions for Files. */}
        {selected?.kind === "changes" && <div className={styles.controlsRow}><GitHeader projectID={projectID} root={root} /></div>}
        {browsingFiles && <div className={styles.controlsRow}><FilesControls projectID={projectID} root={root} showsTree={tabs.showsFileTree} /></div>}
        {browser && <hr className={styles.hairline} />}
        <div className={styles.surfaces}>
          <Surface shown={selected?.kind === "changes"}><Changes projectID={projectID} root={root} visible={visible && selected?.kind === "changes"} /></Surface>
          <Surface shown={browsingFiles}><Files projectID={projectID} root={root} tabs={tabs} visible={visible && browsingFiles} /></Surface>
          {/* Every open browser tab stays mounted so its page, scroll position and dev-server session survive. */}
          {panelBrowsers(tabs).map((id) => (
            <Surface key={id} shown={browser === id}><BrowserPane id={id} projectID={projectID} visible={visible && browser === id} /></Surface>
          ))}
          {!selected && <SurfacePicker root={root} visible={visible} />}
        </div>
      </div>
    </Editors>
  );
}

function Surface({ shown, children }: { shown: boolean; children: React.ReactNode }) {
  return <div className={styles.surface} inert={!shown} aria-hidden={!shown} style={{ visibility: shown ? undefined : "hidden" }}>{children}</div>;
}

function TabStrip({ tabs }: { tabs: PanelTabs }) {
  const strip = useRef<HTMLDivElement>(null);
  const selectedKey = tabs.selected ? tabKey(tabs.selected) : undefined;
  useEffect(() => { strip.current?.querySelector<HTMLElement>("[data-selected=true]")?.scrollIntoView({ block: "nearest", inline: "nearest" }); }, [selectedKey]);
  if (!tabs.tabs.length) return <div className={styles.tabScroller} />;
  return (
    <div ref={strip} className={styles.tabScroller}>
      <div className={styles.tabTrack} role="tablist" aria-label="Review panel tabs">
        {tabs.tabs.map((tab) => <TabChip key={tabKey(tab)} tab={tab} tabs={tabs} />)}
      </div>
    </div>
  );
}

/** One tab on the segmented capsule; the close button appears for the selected or hovered tab. */
function TabChip({ tab, tabs }: { tab: PanelTab; tabs: PanelTabs }) {
  const selected = tabsEqual(tab, tabs.selected);
  const root = useApp((s) => checkoutRoot(s));
  const changes = useReview((s) => root ? s.checkouts[root]?.files.length ?? 0 : 0);
  const page = useBrowsers((s) => tab.kind === "browser" ? s.pages[tab.id] : undefined);
  const project = useApp((s) => selectedProject(s)?.id);
  const preview = tab.kind === "file" && tabs.preview === tab.path;
  const isPrivate = tab.kind === "browser" && isPrivateBrowser(tabs, tab.id);
  const title = tab.kind === "changes" ? "Changes" : tab.kind === "files" ? "Files" : tab.kind === "file" ? tab.path.split("/").at(-1)! : browserTitle(page, isPrivate);
  const help = tab.kind === "file" ? tab.path : tab.kind === "browser" ? page?.url ?? page?.address ?? title : title;
  const others = tabs.tabs.filter((t) => !tabsEqual(t, tab));
  const pin = () => { if (tab.kind === "file" && project) run("store", "updatePanelTabsAction", project, { type: "pin", path: tab.path }); };

  return (
    <div className={cx(styles.tab, selected && styles.selectedTab)} data-selected={selected}
      onContextMenu={contextMenu(() => [
        ...(preview ? [{ label: "Keep Open", action: pin }] : []),
        { label: "Close Tab", action: () => closePanelTab(tab) },
        { label: "Close Other Tabs", enabled: others.length > 0, action: () => others.forEach(closePanelTab) },
      ])}>
      <button type="button" role="tab" aria-selected={selected} title={help} className={styles.tabButton} style={{ fontStyle: preview ? "italic" : undefined }}
        onClick={() => showPanel({ type: "select", tab })} onDoubleClick={pin}>
        {tab.kind === "changes" ? <ChangesIcon size={11} /> : tab.kind === "files" ? <FilesIcon size={11} /> : tab.kind === "file" ? <FileText size={11} /> : isPrivate ? <EyeOff size={11} /> : <Globe size={11} />}
        <span className={styles.tabTitle}>{title}</span>
        {tab.kind === "changes" && <span className={styles.tabCount}>{changes}</span>}
      </button>
      <button type="button" className={styles.tabClose} aria-label="Close tab" title="Close tab (⌘W)" onClick={() => closePanelTab(tab)}><X size={9} strokeWidth={3} /></button>
    </div>
  );
}

/** Shown when every panel tab is closed. Its letter keys work while it has focus. */
function SurfacePicker({ root, visible }: { root: string; visible: boolean }) {
  const changes = useReview((s) => s.checkouts[root]?.files.length ?? 0);
  const focus = useUI((s) => s.reviewFocus);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => { if (visible) box.current?.focus(); }, [visible, focus]);
  const row = (title: string, icon: React.ReactNode, key: string, action: () => void, accessory?: React.ReactNode) => (
    <div className={styles.surfaceRow}>
      <button type="button" className={styles.surfaceButton} onClick={action}>{icon}<span>{title}</span></button>
      {accessory}
      <kbd title={`Press ${key} while this panel is focused`}>{key}</kbd>
    </div>
  );
  return (
    <div ref={box} className={styles.picker} tabIndex={0}
      onKeyDown={(e) => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const key = e.key.toLowerCase();
        if (key === "b") { e.preventDefault(); openBrowserTab(e.shiftKey); }
        else if (key === "f") { e.preventDefault(); showPanel({ type: "showFiles" }); }
        else if (key === "c") { e.preventDefault(); showPanel({ type: "showChanges" }); }
      }}>
      <h3>Open a surface</h3>
      <div className={styles.surfaceList}>
        {row("Browser", <Globe size={15} />, "B", () => openBrowserTab(),
          <button type="button" className={styles.surfaceMenu} aria-label="Browser options" title="Browser or private browser"
            onClick={(e) => void popup([{ label: "Browser", action: () => openBrowserTab() }, { label: "Private Browser", action: () => openBrowserTab(true) }], e.currentTarget)}>
            <ChevronDown size={11} />
          </button>)}
        {row("Files", <FilesIcon size={15} />, "F", () => showPanel({ type: "showFiles" }))}
        {row("Changes", <ChangesIcon size={15} />, "C", () => showPanel({ type: "showChanges" }), <span className={styles.surfaceCount}>{changes}</span>)}
      </div>
    </div>
  );
}
