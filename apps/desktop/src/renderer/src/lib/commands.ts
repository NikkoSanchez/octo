import { harnessTitle, annotationLabel, attachmentLabel, type PanelTab } from "@octo/core";
import { reasoningTitle } from "@octo/agents/model";
import { menuShortcutMatches, type MenuCommand } from "../../../shared/menu";
import { preferredTarget } from "../../../shared/openTargets";
import { appState, checkoutRoot, isProjectChat, selectedProject, selectedThread } from "../state/app";
import { toggleSidebar, useUI, workspaceLayout } from "../state/ui";
import { closeTerminal, useTerminal } from "../state/terminal";
import { reviewFor, toggleScope, toggleWrapLines } from "../state/review";
import { refreshCheckout } from "../state/git";
import { saveFile, useFiles, fileKey } from "../state/files";
import { call, isMac, run } from "../bridge";
import {
  attachToDraft, closePanelTab, cycleThread, editSidebar, newChat, newThread, openBrowserTab, openTerminal, requestFileAction, showBrowser,
  showPanel, toggleReview,
} from "./workspace";

/**
 * A workspace command: the menu bar, the palette, the key router and
 * ⌘-hold hints all read this one list.
 */
export interface Command extends MenuCommand {
  /** For the palette: Create, Navigate, Panels, Conversation, Review, Terminal, Thread, Project, Agent, Draft, App. */
  group: string;
  /** Unavailable while the terminal shows, so the key reaches the shell. */
  terminalAllowed?: boolean;
  /** Available only while the terminal shows. */
  terminalRequired?: boolean;
  action(): void;
}

const key = (accelerator: string) => `CommandOrControl+${accelerator}`;

export function isAvailable(command: Command, inTerminal: boolean): boolean {
  return command.enabled && (!inTerminal || command.terminalAllowed !== false) && (inTerminal || !command.terminalRequired);
}

/** The commands for the current state. Cheap enough to build per key press. */
export function commands(): Command[] {
  const state = appState(), ui = useUI.getState();
  const project = selectedProject(state), thread = selectedThread(state);
  const hasProject = isProjectChat(state), hasThread = !!thread;
  const idle = thread ? !state.running.includes(thread.id) : false;
  const root = checkoutRoot(state);
  const review = hasProject ? reviewFor(root) : undefined;
  const tabs = project?.panelTabs;
  const browsingFiles = tabs?.selected?.kind === "file" || tabs?.selected?.kind === "files";
  const selectedFile = tabs?.selected?.kind === "file" ? tabs.selected.path : undefined;
  const fileSession = root && selectedFile ? useFiles.getState().sessions[fileKey(root, selectedFile)] : undefined;
  const codeSelection = browsingFiles ? review?.fileSelection : review?.selection;
  const terminal = useTerminal.getState().workspace;
  const terminalTab = project ? terminal.tabs.find((t) => t.id === terminal.selected[project.id]) : undefined;
  const terminalShowing = ui.showingTerminal && hasProject;
  const tabShowing = terminalShowing && !!terminalTab;
  const draftText = thread ? ui.drafts[thread.id] ?? "" : "";
  const canSend = !!thread && state.canSave && !state.importingImages.includes(thread.id) && (!!draftText.trim() || !!state.drafts[thread.id]?.images.length);
  const target = preferredTarget(state.openTarget);
  const terminalCommand = (id: string, title: string, accelerator: string | undefined, action: () => void, enabled = tabShowing): Command =>
    ({ id, title, group: "Terminal", accelerator, enabled, terminalRequired: true, action });

  const result: Command[] = [
    { id: "newThread", title: "New Thread", group: "Create", accelerator: key("N"), enabled: state.canSave, action: () => newThread() },
    { id: "newChat", title: "New Chat Without a Project", group: "Create", enabled: state.canSave, action: newChat },
    { id: "openChats", title: "Go to Chats", group: "Navigate", enabled: true, action: () => { run("store", "openChats"); useUI.getState().focusComposer(); } },
    { id: "addProject", title: "Add Project…", group: "Create", accelerator: key("Shift+O"), enabled: state.canSave, action: () => run("store", "chooseProject") },
    // In the sidebar while it shows, as in Messages; otherwise the palette.
    { id: "chats", title: "Search Chats…", group: "Navigate", accelerator: key("K"), enabled: true, action: () => {
      if (workspaceLayout(window.innerWidth, ui).sidebarVisible) useUI.setState((s) => ({ sidebarSearchRequest: s.sidebarSearchRequest + 1 }));
      else useUI.setState({ palette: "chats" });
    } },
    { id: "projects", title: "Switch Project…", group: "Navigate", accelerator: key("Shift+K"), enabled: true, action: () => useUI.setState({ palette: "projects" }) },
    { id: "commands", title: "Command Palette…", group: "Navigate", accelerator: key("Shift+P"), enabled: true, action: () => useUI.setState({ palette: "commands" }) },
    { id: "files", title: "Find File…", group: "Navigate", accelerator: key("P"), enabled: hasProject, action: () => useUI.setState({ palette: "files" }) },
    { id: "previousThread", title: "Previous Thread", group: "Navigate", accelerator: key("Alt+["), enabled: hasThread, action: () => cycleThread(-1) },
    { id: "nextThread", title: "Next Thread", group: "Navigate", accelerator: key("Alt+]"), enabled: hasThread, action: () => cycleThread(1) },
    { id: "sidebar", title: "Toggle Left Sidebar", group: "Panels", accelerator: key("B"), enabled: true, action: toggleSidebar },
    { id: "review", title: "Toggle Review Panel", group: "Panels", accelerator: key("Alt+B"), enabled: hasProject, action: toggleReview },
    { id: "composer", title: "Focus Thread / Composer", group: "Panels", accelerator: key("1"), enabled: hasThread, action: () => useUI.getState().focusComposer() },
    { id: "changes", title: "Show Changes", group: "Panels", accelerator: key("2"), enabled: hasProject, action: () => showPanel({ type: "showChanges" }) },
    { id: "browseFiles", title: "Show Files", group: "Panels", accelerator: key("3"), enabled: hasProject, action: () => showPanel({ type: "showFiles" }) },
    { id: "browser", title: "Show Browser", group: "Panels", accelerator: key("5"), enabled: hasProject, action: showBrowser },
    { id: "newBrowserTab", title: "New Browser Tab", group: "Panels", enabled: hasProject, action: () => openBrowserTab() },
    { id: "newPrivateBrowserTab", title: "New Private Browser Tab", group: "Panels", enabled: hasProject, action: () => openBrowserTab(true) },
    { id: "previousPanelTab", title: "Previous Panel Tab", group: "Panels", accelerator: key("Shift+["), enabled: hasProject && ui.showingReview, terminalAllowed: false,
      action: () => showPanel({ type: "selectAdjacent", offset: -1 }) },
    { id: "nextPanelTab", title: "Next Panel Tab", group: "Panels", accelerator: key("Shift+]"), enabled: hasProject && ui.showingReview, terminalAllowed: false,
      action: () => showPanel({ type: "selectAdjacent", offset: 1 }) },
    { id: "usageDashboard", title: "Usage Dashboard", group: "Panels", enabled: true, action: () => useUI.setState({ usageDashboard: true }) },
    { id: "terminal", title: "Toggle Project Terminal", group: "Panels", accelerator: key("J"), enabled: hasProject, action: () => {
      if (useUI.getState().showingTerminal) useUI.getState().focusComposer(); else if (project) openTerminal(project.id);
    } },
    { id: "find", title: "Find in Current Thread", group: "Conversation", accelerator: key("F"), enabled: hasThread, action: () => {
      useUI.setState((s) => ({
        compactSidebarOpen: false, showingTerminal: false, findingThread: true, findFocus: s.findFocus + 1,
        showingReview: workspaceLayout(window.innerWidth, s).detailWidth < 737 ? false : s.showingReview,
      }));
    } },
    { id: "findNext", title: "Next Matching Message", group: "Conversation", accelerator: key("G"), enabled: ui.findingThread, terminalAllowed: false,
      action: () => useUI.setState((s) => ({ findStep: { delta: 1, request: s.findStep.request + 1 } })) },
    { id: "findPrevious", title: "Previous Matching Message", group: "Conversation", accelerator: key("Shift+G"), enabled: ui.findingThread, terminalAllowed: false,
      action: () => useUI.setState((s) => ({ findStep: { delta: -1, request: s.findStep.request + 1 } })) },
    { id: "send", title: idle || !hasThread ? "Send Message" : "Queue Message", group: "Conversation", accelerator: key("Enter"), enabled: canSend, terminalAllowed: false,
      action: () => useUI.setState((s) => ({ sendRequest: s.sendRequest + 1 })) },
    { id: "stop", title: "Stop Agent", group: "Conversation", accelerator: key("."), enabled: hasThread && !idle, terminalAllowed: false,
      action: () => { if (thread) run("store", "stop", thread.id); } },
    { id: "refresh", title: "Refresh Changes and Files", group: "Review", accelerator: key("Shift+R"), enabled: hasProject,
      action: () => { if (project && root) void refreshCheckout(project.id, root); } },
    { id: "newFile", title: "New File…", group: "Review", enabled: hasProject, action: () => requestFileAction("create", "") },
    { id: "saveFile", title: "Save File", group: "Review", accelerator: key("S"), enabled: hasProject && ui.showingReview && !!fileSession, terminalAllowed: false,
      action: () => { if (fileSession) void saveFile(fileSession.root, fileSession.path); } },
    { id: "deleteFile", title: "Delete File…", group: "Review", enabled: hasProject && !!selectedFile, action: () => { if (selectedFile) requestFileAction("delete", selectedFile); } },
    { id: "focusReview", title: "Focus Code Preview", group: "Review", accelerator: key("4"), enabled: hasProject && !!tabs?.selected && tabs.selected.kind !== "browser",
      action: () => useUI.setState((s) => ({ compactSidebarOpen: false, showingTerminal: false, showingReview: true, reviewFocus: s.reviewFocus + 1 })) },
    { id: "attach", title: "Attach Selected Code to Draft", group: "Review", accelerator: key("Shift+A"), enabled: hasProject && !!codeSelection && ui.showingReview, terminalAllowed: false,
      action: () => { if (codeSelection) { attachToDraft(codeSelection); useUI.getState().focusComposer(); } } },
    { id: "editor", title: `Open Selected File in ${target.title}`, group: "Review", accelerator: key("Shift+E"), enabled: hasProject && !!(selectedFile ?? review?.current?.path),
      action: () => {
        const path = selectedFile ?? review?.current?.path;
        if (project && root && path) run("app", "openTarget", target.id, { projectID: project.id, checkout: root, path, line: codeSelection?.newLines?.[0] ?? 1 });
      } },
    { id: "scope", title: "Toggle Working / Staged Changes", group: "Review", enabled: hasProject && !browsingFiles && !!review?.selectedPath,
      action: () => { if (root) void toggleScope(root); } },
    { id: "wrapLines", title: "Toggle Line Wrapping", group: "Review", enabled: hasProject, action: toggleWrapLines },
    { id: "newTerminal", title: "New Terminal Tab", group: "Terminal", accelerator: key("T"), enabled: hasProject,
      action: () => { if (project) { run("terminal", "newTab", project.id); useUI.getState().showTerminal(true); } } },
    // ⌘W closes the focused pane, as in Ghostty; a tab's last pane closes the tab after confirmation.
    terminalCommand("closeTerminal", terminalTab && terminalTab.panes.length > 1 ? "Close Terminal Pane" : "Close Terminal Tab…", key("W"),
      () => { if (terminalTab) void closeTerminal(terminalTab.id, terminalTab.panes.length > 1); }),
    // Ghostty's default bindings; a binding in the user's Ghostty config takes precedence inside the terminal.
    terminalCommand("splitRight", "Split Terminal Right", key("D"), () => { if (terminalTab) run("terminal", "split", terminalTab.id, "right"); }),
    terminalCommand("splitDown", "Split Terminal Down", key("Shift+D"), () => { if (terminalTab) run("terminal", "split", terminalTab.id, "down"); }),
    terminalCommand("previousPane", "Previous Terminal Pane", key("["), () => { if (terminalTab) run("terminal", "focusDirection", terminalTab.id, "previous"); }),
    terminalCommand("nextPane", "Next Terminal Pane", key("]"), () => { if (terminalTab) run("terminal", "focusDirection", terminalTab.id, "next"); }),
    ...(["left", "right", "up", "down"] as const).map((direction) => terminalCommand(`focusPane-${direction}`, `Focus Terminal Pane ${direction[0].toUpperCase()}${direction.slice(1)}`,
      key(`Alt+${direction[0].toUpperCase()}${direction.slice(1)}`), () => { if (terminalTab) run("terminal", "focusDirection", terminalTab.id, direction); })),
    terminalCommand("zoomPane", "Zoom Terminal Pane", key("Shift+Enter"), () => { if (terminalTab) run("terminal", "toggleZoom", terminalTab.id); }),
    terminalCommand("equalizePanes", "Equalize Terminal Panes", "CommandOrControl+Control+=", () => { if (terminalTab) run("terminal", "equalize", terminalTab.id); }),
    terminalCommand("renameTerminal", "Rename Terminal Tab…", undefined, () => { if (terminalTab) useUI.setState({ renamingTerminal: terminalTab.id }); }),
    terminalCommand("previousTab", "Previous Terminal Tab", key("Shift+["), () => { if (project) run("terminal", "cycle", project.id, -1); }, terminalShowing),
    terminalCommand("nextTab", "Next Terminal Tab", key("Shift+]"), () => { if (project) run("terminal", "cycle", project.id, 1); }, terminalShowing),
    { id: "settings", title: "Settings…", group: "App", accelerator: key(","), enabled: true, action: () => useUI.setState({ settings: "appearance" }) },
    { id: "pinThread", title: thread?.isPinned ? "Unpin Thread" : "Pin Thread", group: "Thread", enabled: hasThread, action: () => { if (thread) run("store", "toggleThreadPin", thread.id); } },
    { id: "renameThread", title: "Rename Thread…", group: "Thread", enabled: hasThread, action: () => editSidebar("rename", true) },
    { id: "deleteThread", title: "Delete Thread…", group: "Thread", enabled: hasThread && idle, action: () => editSidebar("remove", true) },
    { id: "pinProject", title: project?.isPinned ? "Unpin Project" : "Pin Project", group: "Project", enabled: hasProject, action: () => { if (project) run("store", "toggleProjectPin", project.id); } },
    { id: "collapseProject", title: project?.isCollapsed ? "Expand Project" : "Collapse Project", group: "Project", enabled: hasProject,
      action: () => { if (project) { useUI.setState({ sidebarOpen: true }); run("store", "toggleProjectCollapse", project.id); } } },
    { id: "renameProject", title: "Rename Project…", group: "Project", enabled: hasProject, action: () => editSidebar("rename", false) },
    { id: "revealProject", title: "Reveal Project in Finder", group: "Project", enabled: hasProject, action: () => { if (project) run("app", "revealInFinder", project.rootPath); } },
    { id: "removeProject", title: "Remove Project…", group: "Project",
      enabled: hasProject && !!project && !project.threads.some((t) => state.running.includes(t.id)) && !terminal.tabs.some((t) => t.projectID === project.id),
      action: () => editSidebar("remove", false) },
  ];

  // Only listed while a closable tab shows, so ⌘W otherwise keeps its window behavior.
  if (hasProject && ui.showingReview && tabs?.selected) {
    const tab: PanelTab = tabs.selected;
    result.push({ id: "closePanelTab", title: "Close Panel Tab", group: "Panels", accelerator: key("W"), enabled: true, terminalAllowed: false, action: () => closePanelTab(tab) });
  }
  if (hasProject && ui.showingReview && tabs?.selected?.kind === "browser") {
    const id = tabs.selected.id;
    result.push({ id: "hardReload", title: "Hard Reload Browser Page", group: "Panels", enabled: true, action: () => run("browser", "hardReload", id) });
    result.push({ id: "webInspector", title: "Open Web Inspector", group: "Panels", enabled: true, action: () => run("browser", "openDevTools", id) });
  }
  for (const other of state.archive.projects.filter((p) => !p.isChatCollection)) {
    result.push({ id: `project-${other.id}`, title: `Switch to Project: ${other.name}`, group: "Project", enabled: true,
      action: () => { run("store", "selectProject", other.id); useUI.getState().focusComposer(); } });
  }
  if (thread) {
    const directory = thread.workingDirectory;
    for (const descriptor of state.descriptors) {
      result.push({ id: `provider-${descriptor.id}`, title: `Provider: ${harnessTitle(descriptor.id)}`, group: "Agent", enabled: idle && !!descriptor.executable,
        action: () => run("store", "changeHarness", descriptor.id) });
    }
    const catalog = state.modelCatalogs[`${thread.harness}:${directory}`] ?? [];
    for (const model of catalog.filter((m) => !m.hidden)) {
      result.push({ id: `model-${model.model}`, title: `Model: ${model.displayName}`, group: "Agent", enabled: idle, action: () => run("store", "selectModel", model.model) });
      if (model.model === thread.agentSettings.model) {
        for (const effort of model.supportedReasoningEfforts) {
          result.push({ id: `effort-${effort.reasoningEffort}`, title: `Reasoning: ${reasoningTitle(effort.reasoningEffort)}`, group: "Agent", enabled: idle,
            action: () => run("store", "selectReasoning", effort.reasoningEffort) });
        }
      }
    }
    if (state.descriptors.find((d) => d.id === thread.harness)?.supportsModels) {
      result.push({ id: "refreshModels", title: "Refresh Models", group: "Agent", enabled: !state.loadingModels.includes(`${thread.harness}:${directory}`),
        action: () => run("store", "loadModels", directory, thread.harness, true) });
    }
    for (const approval of state.approvals[thread.id] ?? []) {
      result.push({ id: `approval-${approval.id}`, title: `Review Approval: ${approval.title}`, group: "Agent", enabled: true, action: () => {
        useUI.setState({ showingTerminal: false });
        void call("app", "confirm", { message: approval.title, detail: approval.detail, buttons: ["Cancel", "Decline", "Allow Once"] }).then((choice) => {
          if (!appState().approvals[thread.id]?.some((a) => a.id === approval.id)) return;
          if (choice === 1) run("store", "answer", approval.id, thread.id, false);
          else if (choice === 2) run("store", "answer", approval.id, thread.id, true);
        });
      } });
    }
    const draft = state.drafts[thread.id];
    for (const attachment of draft?.code ?? []) {
      result.push({ id: `removeCode-${attachment.id}`, title: `Remove Code Attachment: ${attachmentLabel(attachment)}`, group: "Draft", enabled: true,
        action: () => run("store", "removeDraftCode", thread.id, attachment.id) });
    }
    for (const annotation of draft?.annotations ?? []) {
      result.push({ id: `removeAnnotation-${annotation.id}`, title: `Remove Browser Annotation: ${annotationLabel(annotation)}`, group: "Draft", enabled: true,
        action: () => run("store", "removeDraftAnnotation", thread.id, annotation.id) });
    }
    for (const image of draft?.images ?? []) {
      result.push({ id: `removeImage-${image.id}`, title: `Remove Screenshot: ${image.name}`, group: "Draft", enabled: true,
        action: () => run("store", "removeDraftImage", thread.id, image.id) });
    }
  }
  return result;
}

/** The command a key press runs. Terminal and panel commands may share a key; the visible surface's command wins. */
export function commandForKey(event: Pick<KeyboardEvent, "metaKey" | "ctrlKey" | "shiftKey" | "altKey" | "code">, list: Command[], inTerminal: boolean): Command | undefined {
  const input = { code: event.code, meta: event.metaKey, control: event.ctrlKey, shift: event.shiftKey, alt: event.altKey };
  const matching = list.filter((c) => menuShortcutMatches(c.accelerator, input, isMac));
  return matching.find((c) => (c.terminalAllowed !== false || !inTerminal) && (!c.terminalRequired || inTerminal)) ?? matching[0];
}

/** The menu bar's view of the commands: each enabled as it would be from the keyboard right now. */
export function menuCommands(list: Command[], inTerminal: boolean): MenuCommand[] {
  return list.map(({ id, title, group, accelerator, ...command }) => ({ id, title, group, accelerator, enabled: isAvailable({ id, title, group, accelerator, ...command }, inTerminal) }));
}
