import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ChartNoAxesColumn, ChevronDown, ChevronRight, MessageSquare, PanelLeft, Pin, Plus, Search, Settings, SquareTerminal, X } from "lucide-react";
import { hasUnreadCompletion, searchableThreads, threadActivityAt, ThreadSearch } from "@octo/core";
import { appState, useAppPresentation } from "../../state/app";
import { SIDEBAR_THREAD_INITIAL, SIDEBAR_THREAD_PAGE, toggleSidebar, useUI } from "../../state/ui";
import { useTerminal } from "../../state/terminal";
import { selectedPlace, sidebarPresentation, type SidebarPlace, type SidebarProject, type SidebarThread } from "../../lib/sidebar";
import { contextMenu, type MenuSpec } from "../../lib/menu";
import { navigateThread, newChat, newThread, openTerminal } from "../../lib/workspace";
import { run } from "../../bridge";
import { CornerButton, cx, GlassPanel, HoverButton, ShortcutHint, ThreadAvatar } from "../controls";
import { ProjectFolderIcon } from "../icons";
import { Popover } from "../Popover";
import { AccountUsage } from "../overlays/AccountUsage";
import { noteSidebarScroll, SidebarSeparator, ThreadRow } from "./ThreadRow";
import styles from "./sidebar.module.css";

function threadMenu(thread: SidebarThread, chats: boolean): MenuSpec[] {
  return [
    { label: thread.pinned ? "Unpin Thread" : "Pin Thread", action: () => run("store", "toggleThreadPin", thread.id) },
    { label: "Rename…", action: () => useUI.setState({ sidebarEdit: { kind: "rename", projectID: thread.projectID, threadID: thread.id } }) },
    { label: chats ? "New Chat" : "New Thread in Project", action: () => newThread(thread.projectID) },
    { type: "separator" },
    { label: "Delete Thread…", enabled: !thread.running, action: () => useUI.setState({ sidebarEdit: { kind: "remove", projectID: thread.projectID, threadID: thread.id } }) },
  ];
}

function projectMenu(project: SidebarProject): MenuSpec[] {
  return [
    { label: "New Thread", action: () => newThread(project.id) },
    { label: "Open Terminal", action: () => openTerminal(project.id) },
    { type: "separator" },
    { label: project.pinned ? "Unpin Project" : "Pin Project", action: () => run("store", "toggleProjectPin", project.id) },
    { label: project.collapsed ? "Expand Project" : "Collapse Project", action: () => run("store", "toggleProjectCollapse", project.id) },
    { label: "Rename…", action: () => useUI.setState({ sidebarEdit: { kind: "rename", projectID: project.id } }) },
    { label: "Reveal in Finder", action: () => run("app", "revealInFinder", project.root) },
    { type: "separator" },
    { label: "Add Project…", action: () => run("store", "chooseProject") },
    { label: "Remove Project…", enabled: !project.busy, action: () => useUI.setState({ sidebarEdit: { kind: "remove", projectID: project.id } }) },
  ];
}

/**
 * The sidebar card, after macOS 26 Messages: the list scrolls
 * beneath the search field and the footer controls. While searching, results cover the list, which
 * stays mounted to keep its scroll position.
 */
export function Sidebar() {
  const limits = useUI((s) => s.sidebarThreadLimits);
  const showingTerminal = useUI((s) => s.showingTerminal);
  const searchRequest = useUI((s) => s.sidebarSearchRequest);
  const terminalTabs = useTerminal((s) => s.workspace.tabs);
  const tabCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const tab of terminalTabs) counts[tab.projectID] = (counts[tab.projectID] ?? 0) + 1;
    return counts;
  }, [terminalTabs]);
  const data = useAppPresentation((s) => sidebarPresentation(s, limits, showingTerminal, tabCounts));

  const [searching, setSearching] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<{ id: string; projectID: string; snippet?: string }[]>([]);
  const [highlighted, setHighlighted] = useState<string>();
  const [showingUsage, setShowingUsage] = useState(false);
  // The selected thread and the place it was clicked; cleared when something else selects.
  const [openedFrom, setOpenedFrom] = useState<{ thread: string; place: SidebarPlace }>();
  const searchField = useRef<HTMLInputElement>(null), usageButton = useRef<HTMLButtonElement>(null);

  const beginSearch = useCallback(() => {
    setSearching(true);
    requestAnimationFrame(() => searchField.current?.focus());
  }, []);
  useEffect(() => { if (searchRequest) beginSearch(); }, [searchRequest, beginSearch]);
  useEffect(() => { if (openedFrom && openedFrom.thread !== data.selectedThread) setOpenedFrom(undefined); }, [data.selectedThread, openedFrom]);

  // Searching runs after the keystroke renders; a newer query supersedes the running one.
  const trimmed = query.trim();
  useEffect(() => {
    if (!searching || !trimmed) { setResults([]); return; }
    const timer = setTimeout(() => {
      const entries = searchableThreads(appState().archive);
      const found = ThreadSearch.results(query, entries).flatMap((r) => {
        const entry = entries.find((e) => e.thread.id === r.threadID);
        return entry ? [{ id: entry.thread.id, projectID: entry.project.id, snippet: r.snippet }] : [];
      });
      setResults(found);
      setHighlighted((current) => found.some((r) => r.id === current) ? current : found[0]?.id);
    }, 0);
    return () => clearTimeout(timer);
  }, [query, trimmed, searching, data]);

  /** Escape clears the text first, then leaves search. */
  const cancelSearch = () => {
    if (query) { setQuery(""); return; }
    setSearching(false); setHighlighted(undefined); searchField.current?.blur();
  };
  const open = useCallback((thread: SidebarThread, place?: SidebarPlace) => {
    setOpenedFrom(place ? { thread: thread.id, place } : undefined);
    navigateThread(thread.id, thread.projectID);
  }, []);
  const openFrom = useMemo(() => ({
    home: (t: SidebarThread) => open(t, "home"), recent: (t: SidebarThread) => open(t, "recent"),
    pinned: (t: SidebarThread) => open(t, "pinned"), search: (t: SidebarThread) => open(t),
  }), [open]);
  const chatsID = data.chats?.id;
  const menus = useMemo(() => ({ chats: (t: SidebarThread) => threadMenu(t, true), project: (t: SidebarThread) => threadMenu(t, false) }), []);
  /** For lists that mix Chats and projects. */
  const rowMenu = useCallback((t: SidebarThread) => threadMenu(t, t.projectID === chatsID), [chatsID]);

  // Only one place draws the selection: where it was opened, while listed there, otherwise its project.
  const selectedThread = showingTerminal ? undefined : data.selectedThread;
  const owner = data.chats?.id === data.selectedProject ? data.chats : data.projects.find((p) => p.id === data.selectedProject);
  const ownerThread = owner?.threads.find((t) => t.id === selectedThread);
  const shown = selectedThread ? selectedPlace(openedFrom?.thread === selectedThread ? openedFrom.place : undefined, (place) => {
    switch (place) {
      case "pinned": return data.pinned.some((t) => t.id === selectedThread);
      case "home": return !!owner && (owner.id === data.chats?.id ? !owner.collapsed : !data.projectsCollapsed);
      case "recent": return !data.recentCollapsed && !!ownerThread?.hasMessages;
    }
  }) : undefined;
  const selectedIn = (place: SidebarPlace) => shown === place ? selectedThread : undefined;
  const showingResults = searching && !!trimmed;
  const rowsByID = useMemo(() => new Map([...(data.chats ? [data.chats] : []), ...data.projects].flatMap((p) => p.threads).concat(data.recent).map((t) => [t.id, t])), [data]);

  return (
    <GlassPanel className={styles.sidebar}>
      <aside data-testid="sidebar" aria-label="Chats and projects" className={styles.inner}>
        {/* The traffic lights sit in this row's leading space. */}
        <div className={styles.topBar}>
          <div className={styles.chromeRow}>
            <CornerButton aria-label="Hide sidebar" help="Hide sidebar (⌘B)" onClick={toggleSidebar}><PanelLeft size={15} /><ShortcutHint command="sidebar" /></CornerButton>
          </div>
          <div className={cx(styles.searchField, searching && styles.searching)} onClick={() => { if (!searching) beginSearch(); }}
            title={searching ? undefined : "Search all chats (⌘K)"}>
            <Search size={13} strokeWidth={2.2} />
            {searching ? <>
              <input ref={searchField} autoFocus data-plain aria-label="Search all chats" placeholder="Search" value={query}
                onChange={(e) => setQuery(e.target.value)}
                onBlur={() => { if (!query) setSearching(false); }}
                onKeyDown={(e) => {
                  if (e.key === "Escape") { e.preventDefault(); cancelSearch(); }
                  else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                    e.preventDefault();
                    const index = results.findIndex((r) => r.id === highlighted), offset = e.key === "ArrowDown" ? 1 : -1;
                    const next = results[Math.min(results.length - 1, Math.max(0, (index < 0 ? (offset > 0 ? -1 : results.length) : index) + offset))];
                    if (next) setHighlighted(next.id);
                  } else if (e.key === "Enter") {
                    const target = rowsByID.get(highlighted ?? results[0]?.id ?? "") ?? resultRow(results.find((r) => r.id === (highlighted ?? results[0]?.id)));
                    if (target) { e.preventDefault(); open(target); }
                  }
                }} />
              <button type="button" className={styles.endSearch} aria-label="End search" title="End search" onMouseDown={(e) => e.preventDefault()}
                onClick={(e) => { e.stopPropagation(); setQuery(""); setSearching(false); }}><X size={12} strokeWidth={2.5} /></button>
            </> : <>
              <span className={styles.searchLabel}>Search</span>
              <kbd>⌘K</kbd>
              <ShortcutHint command="chats" />
            </>}
          </div>
        </div>
        <div className={styles.scroll} onScroll={noteSidebarScroll}>
          <div className={styles.list} inert={showingResults} aria-hidden={showingResults} style={{ visibility: showingResults ? "hidden" : undefined }}>
            {data.pinned.length > 0 && <PinnedStrip threads={data.pinned} selected={selectedIn("pinned")} open={openFrom.pinned} menu={rowMenu} />}
            {data.chats && (
              <section>
                <RevealRow>
                  <SectionHeader title="Chats" icon={<MessageSquare size={13} />} collapsed={data.chats.collapsed} unread={data.chats.unread} toggle={() => run("store", "toggleProjectCollapse", data.chats!.id)} />
                  <RevealButton label="New chat" help="New chat (⌘N)" onClick={newChat} hint={<ShortcutHint command="newThread" active={data.selectedProject === data.chats.id} />}><Plus size={14} /></RevealButton>
                </RevealRow>
                {!data.chats.collapsed && <>
                  <Rows threads={data.chats.threads} selected={selectedIn("home")} open={openFrom.home} menu={menus.chats} />
                  <LimitControls project={data.chats} />
                  {data.chats.threads.length === 0 && (
                    <HoverButton className={styles.startChat} onClick={newChat}><MessageSquare size={14} />Start a chat</HoverButton>
                  )}
                </>}
              </section>
            )}
            <section>
              <RevealRow>
                <SectionHeader title="Projects" collapsed={data.projectsCollapsed} unread={data.projectsUnread} toggle={() => run("store", "toggleProjectsSection")} />
                <HoverButton padded={false} className={styles.headerButton} aria-label="Switch Project" help="Switch Project (⇧⌘K)" onClick={() => useUI.setState({ palette: "projects" })}><Search size={14} /></HoverButton>
                <RevealButton label="Add Project" help="Add Project (⇧⌘O)" onClick={() => run("store", "chooseProject")}><Plus size={14} /></RevealButton>
              </RevealRow>
              {!data.projectsCollapsed && <>
                {data.projects.map((project) => (
                  <ProjectSection key={project.id} project={project} selected={selectedIn("home")} current={data.selectedProject === project.id}
                    terminalSelected={showingTerminal && data.selectedProject === project.id} tabs={tabCounts[project.id] ?? 0}
                    open={openFrom.home} menu={menus.project} />
                ))}
                {data.projects.length === 0 && <p className={styles.empty}>Add a project to work with your code.</p>}
              </>}
            </section>
            <section>
              <SectionHeader title="Recent" collapsed={data.recentCollapsed} unread={data.recent.filter((t) => t.unread).length} toggle={() => run("store", "toggleRecentSection")} />
              {!data.recentCollapsed && <>
                {data.recent.length === 0 && <p className={styles.empty}>Your conversations will appear here.</p>}
                <Rows threads={data.recent} selected={selectedIn("recent")} open={openFrom.recent} menu={rowMenu} showsProjectName />
              </>}
            </section>
          </div>
          {showingResults && (
            <div className={styles.results} role="listbox" aria-label="Search results">
              <h3 className={styles.resultsHeader}>{results.length ? `Conversations · ${results.length}` : "No results"}</h3>
              {!results.length && <p className={styles.empty}>No chat titles, projects or messages contain “{query}”.</p>}
              {results.map((result, index) => {
                const thread = rowsByID.get(result.id) ?? resultRow(result);
                if (!thread) return null;
                return (
                  <div key={result.id}>
                    <ThreadRow thread={thread} selected={selectedThread === thread.id} highlighted={highlighted === thread.id} showsProjectName
                      snippet={result.snippet} open={openFrom.search} menu={rowMenu} />
                    {index < results.length - 1 && <SidebarSeparator hidden={selectedThread === thread.id || selectedThread === results[index + 1].id} />}
                  </div>
                );
              })}
            </div>
          )}
        </div>
        {/* Settings and Account Usage float on glass over the bottom of the list. */}
        <footer className={styles.footer}>
          <button type="button" className={styles.settings} title="Settings (⌘,)" onClick={() => useUI.setState({ settings: "appearance" })}>
            <Settings size={14} />Settings
          </button>
          <button ref={usageButton} type="button" className={styles.usage} aria-label="Account usage limits" title="Account usage limits"
            onClick={() => setShowingUsage((v) => !v)}>
            <ChartNoAxesColumn size={15} />
          </button>
          {showingUsage && (
            <Popover anchor={usageButton} label="Account usage" width={350} close={() => setShowingUsage(false)}>
              <AccountUsage dismiss={() => setShowingUsage(false)} />
            </Popover>
          )}
        </footer>
      </aside>
    </GlassPanel>
  );
}

/** A search result for a thread not otherwise listed (hidden past a limit or in a collapsed project). */
function resultRow(result: { id: string; projectID: string } | undefined): SidebarThread | undefined {
  if (!result) return undefined;
  const state = appState();
  const project = state.archive.projects.find((p) => p.id === result.projectID);
  const thread = project?.threads.find((t) => t.id === result.id);
  if (!project || !thread) return undefined;
  return {
    id: thread.id, projectID: project.id, projectName: project.isChatCollection ? "Chats" : project.name, title: thread.title, harness: thread.harness,
    pinned: thread.isPinned, unread: hasUnreadCompletion(thread), running: state.running.includes(thread.id),
    activityAt: threadActivityAt(thread), hasMessages: thread.messages.length > 0,
  };
}

/** Rows separated by inset hairlines, hidden beside the selected row as in Messages. */
function Rows({ threads, selected, open, menu, showsProjectName = false }: {
  threads: SidebarThread[]; selected?: string; open: (t: SidebarThread) => void; menu: (t: SidebarThread) => MenuSpec[]; showsProjectName?: boolean;
}) {
  return threads.map((thread, index) => (
    <div key={thread.id}>
      <ThreadRow thread={thread} selected={selected === thread.id} open={open} menu={menu} showsProjectName={showsProjectName} />
      {index < threads.length - 1 && <SidebarSeparator hidden={selected === thread.id || selected === threads[index + 1].id} />}
    </div>
  ));
}

function ProjectSection({ project, selected, current, terminalSelected, tabs, open, menu }: {
  project: SidebarProject; selected?: string; current: boolean; terminalSelected: boolean; tabs: number;
  open: (t: SidebarThread) => void; menu: (t: SidebarThread) => MenuSpec[];
}) {
  return (
    <div className={styles.project} onContextMenu={contextMenu(() => projectMenu(project))}>
      <RevealRow>
        <HoverButton padded={false} selected={current && project.collapsed} className={styles.projectHeader} help={project.root}
          aria-label={`${project.collapsed ? "Expand" : "Collapse"} ${project.name}`} aria-expanded={!project.collapsed}
          onClick={() => run("store", "toggleProjectCollapse", project.id)}>
          {project.collapsed ? <ChevronRight size={10} strokeWidth={3} className={styles.chevron} /> : <ChevronDown size={10} strokeWidth={3} className={styles.chevron} />}
          <span className={styles.folder}><ProjectFolderIcon open={!project.collapsed} /></span>
          <span className={styles.projectName}>{project.name}</span>
          {project.unread > 0 && <span className={styles.badge} title={`${project.unread} completed, unread ${project.unread === 1 ? "thread" : "threads"}`}>{project.unread}</span>}
          {project.pinned && <Pin size={11} fill="currentColor" className={styles.projectPin} />}
        </HoverButton>
        <RevealButton label={`New thread in ${project.name}`} help={`New thread in ${project.name} (⌘N)`} onClick={() => newThread(project.id)}
          hint={<ShortcutHint command="newThread" active={current} />}><Plus size={14} /></RevealButton>
      </RevealRow>
      {!project.collapsed && (
        <div className={styles.projectThreads}>
          <Rows threads={project.threads} selected={selected} open={open} menu={menu} />
          <LimitControls project={project} />
          {project.threads.length > 0 && <SidebarSeparator hidden={terminalSelected || project.threads.at(-1)?.id === selected} />}
          <button type="button" className={cx(styles.terminalRow, terminalSelected && styles.selected)} aria-current={terminalSelected ? "page" : undefined}
            aria-label="Terminal" aria-description={tabs === 0 ? "No open tabs" : `${tabs} open`} onClick={() => openTerminal(project.id)}>
            <span className={styles.unreadDot} />
            <span className={styles.terminalIcon}><SquareTerminal size={15} /></span>
            <span className={styles.threadText}>
              <span className={styles.terminalTitle}>Terminal</span>
              <span className={styles.preview}>{tabs === 0 ? "Shell at the project root" : `${tabs} open ${tabs === 1 ? "tab" : "tabs"}`}</span>
            </span>
          </button>
        </div>
      )}
    </div>
  );
}

function LimitControls({ project }: { project: SidebarProject }) {
  if (project.hidden === 0 && project.limit <= SIDEBAR_THREAD_INITIAL) return null;
  const setLimit = (limit: number | undefined) => useUI.setState((s) => {
    const next = { ...s.sidebarThreadLimits };
    if (limit === undefined) delete next[project.id]; else next[project.id] = limit;
    return { sidebarThreadLimits: next };
  });
  return (
    <div className={styles.limits}>
      {project.hidden > 0 && (
        <HoverButton aria-label={`Show more threads in ${project.name}`} help={`Show ${Math.min(project.hidden, SIDEBAR_THREAD_PAGE)} more of ${project.hidden} hidden`}
          onClick={() => setLimit(project.limit + SIDEBAR_THREAD_PAGE)}>Show more</HoverButton>
      )}
      {project.limit > SIDEBAR_THREAD_INITIAL && (
        <HoverButton aria-label={`Show fewer threads in ${project.name}`} onClick={() => setLimit(undefined)}>Show less</HoverButton>
      )}
    </div>
  );
}

function PinnedStrip({ threads, selected, open, menu }: { threads: SidebarThread[]; selected?: string; open: (t: SidebarThread) => void; menu: (t: SidebarThread) => MenuSpec[] }) {
  return (
    <div className={styles.pinned}>
      {threads.map((thread) => {
        const isSelected = selected === thread.id;
        return (
          <button key={thread.id} type="button" className={cx(styles.pinnedItem, isSelected && styles.selected)} title={thread.title}
            aria-label={`Pinned, ${thread.title}, ${thread.projectName}`} aria-description={thread.running ? "Working" : thread.unread ? "Finished, unread" : "Read"}
            aria-current={isSelected ? "page" : undefined} onClick={() => open(thread)} onContextMenu={contextMenu(() => menu(thread))}>
            <span className={styles.pinnedAvatar}>
              <ThreadAvatar harness={thread.harness} size={48} running={thread.running} />
              {thread.unread && <span className={styles.pinnedUnread} />}
            </span>
            <span className={styles.pinnedTitle}>{thread.title}</span>
            <span className={styles.pinnedProject}>{thread.projectName}</span>
          </button>
        );
      })}
    </div>
  );
}

function SectionHeader({ title, icon, collapsed, unread, toggle }: { title: string; icon?: ReactNode; collapsed: boolean; unread: number; toggle: () => void }) {
  return (
    <HoverButton padded={false} className={styles.sectionHeader} onClick={toggle} aria-expanded={!collapsed}
      aria-label={`${collapsed ? "Expand" : "Collapse"} ${title} section`}>
      {collapsed ? <ChevronRight size={10} strokeWidth={3} className={styles.chevron} /> : <ChevronDown size={10} strokeWidth={3} className={styles.chevron} />}
      {icon}
      <span>{title}</span>
      {collapsed && unread > 0 && <span className={styles.badge}>{unread}</span>}
    </HoverButton>
  );
}

/** A header or project row whose add button appears only while the row is hovered or focused, or hints show. */
function RevealRow({ children }: { children: ReactNode }) {
  return <div className={styles.revealRow}>{children}</div>;
}

function RevealButton({ label, help, onClick, hint, children }: { label: string; help: string; onClick: () => void; hint?: ReactNode; children: ReactNode }) {
  const hints = useUI((s) => s.shortcutHints);
  return (
    <HoverButton padded={false} className={cx(styles.headerButton, styles.reveal, hints && styles.revealed)} aria-label={label} help={help} onClick={onClick}>
      {children}{hint}
    </HoverButton>
  );
}
