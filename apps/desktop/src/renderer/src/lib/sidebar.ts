import { chatsProject, hasUnreadCompletion, orderedProjects, orderedThreads, recentThreads, threadActivityAt, ThreadPreview, type HarnessID, type WorkspaceProject, type WorkspaceThread } from "@octo/core";
import type { AppState } from "../../../shared/state";

/** Long thread lists start short and grow by a page at a time. */
export const SIDEBAR_THREAD_INITIAL = 5, SIDEBAR_THREAD_PAGE = 10;

/** Everything a sidebar row draws. Plain data, so equal rows compare equal and skip rendering. */
export interface SidebarThread {
  id: string;
  projectID: string;
  projectName: string;
  title: string;
  harness: HarnessID;
  pinned: boolean;
  unread: boolean;
  running: boolean;
  /** Last activity, for the row's timestamp. */
  activityAt: number;
  /** Messages' last-message line; undefined while working, when typing dots show instead. */
  preview?: string;
  hasMessages: boolean;
}

export interface SidebarProject {
  id: string;
  name: string;
  root: string;
  pinned: boolean;
  collapsed: boolean;
  unread: number;
  threads: SidebarThread[];
  /** Threads beyond the list's limit. The selected and running threads always stay listed. */
  hidden: number;
  limit: number;
  /** Removing a project waits for its agents and terminal tabs. */
  busy: boolean;
}

export interface SidebarPresentation {
  chats?: SidebarProject;
  projects: SidebarProject[];
  pinned: SidebarThread[];
  recent: SidebarThread[];
  selectedProject?: string;
  selectedThread?: string;
  projectsCollapsed: boolean;
  recentCollapsed: boolean;
  projectsUnread: number;
}

// Previews are reduced once per thread object; a settled thread keeps its object between patches.
const previews = new WeakMap<WorkspaceThread, string | undefined>();
function preview(thread: WorkspaceThread): string | undefined {
  if (!previews.has(thread)) previews.set(thread, ThreadPreview.text(thread));
  return previews.get(thread);
}

function row(thread: WorkspaceThread, project: WorkspaceProject, running: Set<string>): SidebarThread {
  const working = running.has(thread.id);
  return {
    id: thread.id, projectID: project.id, projectName: project.isChatCollection ? "Chats" : project.name,
    title: thread.title, harness: thread.harness, pinned: thread.isPinned, unread: hasUnreadCompletion(thread), running: working,
    // Streamed text never reaches the sidebar: a working thread shows typing dots.
    activityAt: threadActivityAt(thread), preview: working ? undefined : preview(thread), hasMessages: thread.messages.length > 0,
  };
}

/** Long lists start short and grow by a page at a time. The selected and running threads always stay listed. */
export function threadWindow<T extends { id: string; running: boolean }>(threads: T[], limit: number, keep?: string): { threads: T[]; hidden: number } {
  if (threads.length <= limit) return { threads, hidden: 0 };
  const shown = threads.filter((t, index) => index < limit || t.id === keep || t.running);
  return { threads: shown, hidden: threads.length - shown.length };
}

export function sidebarPresentation(state: AppState, limits: Record<string, number>, terminalShowing: boolean, terminalTabs: Record<string, number>): SidebarPresentation {
  const archive = state.archive, running = new Set(state.running);
  const selected = terminalShowing ? undefined : archive.selectedThreadID;
  const project = (p: WorkspaceProject): SidebarProject => {
    const limit = limits[p.id] ?? SIDEBAR_THREAD_INITIAL;
    const window = threadWindow(orderedThreads(p).map((t) => row(t, p, running)), limit, selected);
    return {
      id: p.id, name: p.name, root: p.rootPath, pinned: p.isPinned, collapsed: p.isCollapsed,
      unread: p.threads.filter(hasUnreadCompletion).length, threads: window.threads, hidden: window.hidden, limit,
      busy: p.threads.some((t) => running.has(t.id)) || (terminalTabs[p.id] ?? 0) > 0,
    };
  };
  const chats = chatsProject(archive);
  const projects = orderedProjects(archive);
  return {
    chats: chats && project(chats),
    projects: projects.map(project),
    // Pinned threads also stay in their project; the strip is a shortcut, as pinned conversations are in Messages.
    pinned: [...(chats ? [chats] : []), ...projects].flatMap((p) => orderedThreads(p).filter((t) => t.isPinned).map((t) => row(t, p, running))),
    recent: recentThreads(archive).map(({ project: p, thread }) => row(thread, p, running)),
    selectedProject: archive.selectedProjectID,
    selectedThread: archive.selectedThreadID,
    projectsCollapsed: archive.projectsSectionCollapsed === true,
    recentCollapsed: archive.recentSectionCollapsed === true,
    projectsUnread: projects.reduce((n, p) => n + p.threads.filter(hasUnreadCompletion).length, 0),
  };
}

/** The places one conversation can be listed at once. Only one of them draws the selection. */
export type SidebarPlace = "pinned" | "home" | "recent";

/** The place it was opened from while that is listed, otherwise home, Recent, then the pinned strip. */
export function selectedPlace(openedFrom: SidebarPlace | undefined, listed: (place: SidebarPlace) => boolean): SidebarPlace | undefined {
  if (openedFrom && listed(openedFrom)) return openedFrom;
  return (["home", "recent", "pinned"] as const).find(listed);
}

/** Messages' list timestamp: the time today, "Yesterday", the weekday within a week, else the date. */
export function sidebarTimestamp(date: number, now = Date.now()): string {
  const day = new Date(date), today = new Date(now);
  const start = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((start(today) - start(day)) / 86_400_000);
  if (days <= 0) return day.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  if (days === 1) return "Yesterday";
  if (days < 7) return day.toLocaleDateString(undefined, { weekday: "long" });
  return day.toLocaleDateString(undefined, { year: "2-digit", month: "numeric", day: "numeric" });
}

/** A short age for the hover card: now, 5m, 3h, 2d, 1y. */
export function sidebarAge(date: number, now = Date.now()): string {
  const seconds = Math.max(0, (now - date) / 1000);
  if (seconds < 60) return "now";
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h`;
  if (seconds < 31_536_000) return `${Math.floor(seconds / 86_400)}d`;
  return `${Math.floor(seconds / 31_536_000)}y`;
}
