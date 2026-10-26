import { markdownFileLink, newID, orderedThreads, recentBrowser, searchableThreads, type CodeAttachment, type PanelTab } from "@octo/core";
import type { PanelTabOperation } from "../../../shared/panelTabs";
import { appState, checkoutRoot, isProjectChat, selectedProject } from "../state/app";
import { SIDEBAR_THREAD_INITIAL, SINGLE_REVIEW_WIDTH, useUI, workspaceLayout } from "../state/ui";
import { call, run } from "../bridge";

/** Opens a thread from the sidebar, a search result or the palette. */
export function navigateThread(threadID: string, projectID: string): void {
  run("store", "selectThread", threadID, projectID);
  useUI.setState({ showingTerminal: false, compactSidebarOpen: false });
  useUI.getState().focusComposer();
}

export function newThread(projectID?: string): void {
  run("store", "newThread", projectID ? { projectID } : {});
  useUI.getState().focusComposer();
}

export function newChat(): void {
  run("store", "newChat");
  useUI.getState().focusComposer();
}

export function openTerminal(projectID: string): void {
  void call("store", "openTerminal", projectID).then((selected) => { if (selected) useUI.getState().showTerminal(true); })
    .catch((error) => useUI.getState().showError(String(error)));
}

/** Changes the project's panel tabs and reveals the panel. */
export function showPanel(operation: PanelTabOperation, focus = false): void {
  const state = appState(), project = selectedProject(state);
  if (!project || !isProjectChat(state)) return;
  run("store", "updatePanelTabsAction", project.id, operation);
  useUI.setState((s) => ({ showingTerminal: false, showingReview: true, compactSidebarOpen: false, reviewFocus: focus ? s.reviewFocus + 1 : s.reviewFocus }));
}

export function openBrowserTab(isPrivate = false): void {
  showPanel({ type: "openBrowser", id: newID(), isPrivate });
}

/** The most recent browser tab, or a new one. */
export function showBrowser(): void {
  const project = selectedProject(appState());
  if (!project) return;
  const id = recentBrowser(project.panelTabs);
  if (id) showPanel({ type: "select", tab: { kind: "browser", id } }); else openBrowserTab();
}

export function closePanelTab(tab: PanelTab): void {
  const project = selectedProject(appState());
  if (project) run("store", "updatePanelTabsAction", project.id, { type: "close", tab });
}

export function toggleReview(): void {
  useUI.setState((s) => ({ showingTerminal: false, showingReview: !s.showingReview, projectActions: false }));
}

/** The review card covers the chat below this detail width. */
export function singleReview(): boolean {
  const ui = useUI.getState();
  return isProjectChat(appState()) && ui.showingReview && !ui.showingTerminal && workspaceLayout(window.innerWidth, ui).detailWidth < SINGLE_REVIEW_WIDTH;
}

/** Attaches captured code to the selected thread's draft without sending it. */
export function attachToDraft(attachment: CodeAttachment): void {
  run("store", "attach", attachment);
  if (singleReview()) useUI.getState().focusComposer();
}

/** Opens a link from an agent's reply in the review panel when it names a file in this checkout. */
export function openMarkdownLink(href: string): void {
  if (/^(https?|mailto):/i.test(href)) { run("app", "openExternal", href); return; }
  const state = appState(), project = selectedProject(state), root = checkoutRoot(state);
  if (!project || !root || !isProjectChat(state)) { useUI.getState().showError("Code review is available in project chats."); return; }
  const link = markdownFileLink(href, root);
  if (!link) { useUI.getState().showError("This link does not point to a file inside this thread's checkout."); return; }
  showPanel({ type: "openFile", path: link.path, pinned: false });
  useUI.setState((s) => ({ reviewLocation: { root, path: link.path, line: link.line ?? 1, request: (s.reviewLocation?.request ?? 0) + 1 } }));
}

/** Previous or next thread among those the sidebar lists, as ⌥⌘[ and ⌥⌘]. */
export function cycleThread(delta: number): void {
  const state = appState(), ui = useUI.getState(), archive = state.archive;
  const listed = searchableThreads(archive).filter(({ project, thread }) => {
    if (project.isCollapsed || (!project.isChatCollection && archive.projectsSectionCollapsed)) return thread.id === archive.selectedThreadID;
    const limit = ui.sidebarThreadLimits[project.id] ?? SIDEBAR_THREAD_INITIAL;
    return orderedThreads(project).findIndex((t) => t.id === thread.id) < limit || thread.id === archive.selectedThreadID || state.running.includes(thread.id);
  });
  if (!listed.length) return;
  const index = listed.findIndex((e) => e.thread.id === archive.selectedThreadID);
  const next = listed[(index + delta + listed.length) % listed.length];
  navigateThread(next.thread.id, next.project.id);
}

/** Opens the sidebar for a rename or removal of the selected thread or project. */
export function editSidebar(kind: "rename" | "remove", thread: boolean): void {
  const state = appState(), project = selectedProject(state);
  if (!project) return;
  useUI.setState({ sidebarEdit: { kind, projectID: project.id, threadID: thread ? state.archive.selectedThreadID : undefined } });
}

export function requestFileAction(kind: "create" | "delete", path: string): void {
  const state = appState(), project = selectedProject(state), root = checkoutRoot(state);
  if (!project || !root || !isProjectChat(state)) return;
  useUI.setState({ fileAction: { kind, projectID: project.id, root, path } });
}
