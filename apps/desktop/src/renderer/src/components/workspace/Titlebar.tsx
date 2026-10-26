import { useRef } from "react";
import { MessageSquare, PanelLeft, PanelRight, Search, SquareTerminal } from "lucide-react";
import { harnessTitle } from "@octo/core";
import { checkoutRoot, selectedProject, selectedThread, useApp } from "../../state/app";
import { toggleSidebar, useUI } from "../../state/ui";
import { useReview } from "../../state/review";
import { openTerminal, toggleReview } from "../../lib/workspace";
import { CornerButton, ShortcutHint, ToolbarButton } from "../controls";
import { GitBranchIcon } from "../icons";
import { Popover } from "../Popover";
import { ProjectActions } from "../project/ProjectActions";
import styles from "./workspace.module.css";

/** The titlebar row (32 pt) and its 8 pt margins. */
export const TITLEBAR_HEIGHT = 48;

/**
 * A 32 pt row whose centre line is the traffic lights', shared by the sidebar card's hide button, so
 * the show-sidebar button doesn't drop when the sidebar closes. With the sidebar hidden the traffic
 * lights float over this row's leading edge.
 */
export function Titlebar({ showSidebarToggle, projectActionsFloat }: { showSidebarToggle: boolean; projectActionsFloat: boolean }) {
  const info = useApp((s) => {
    const project = selectedProject(s), thread = selectedThread(s);
    return {
      projectID: project?.id, projectName: project?.name, chats: project?.isChatCollection ?? false,
      threadTitle: thread?.title, harness: thread?.harness, root: checkoutRoot(s),
    };
  });
  const showingTerminal = useUI((s) => s.showingTerminal), showingReview = useUI((s) => s.showingReview);
  const projectActions = useUI((s) => s.projectActions);
  const branch = useReview((s) => info.root ? s.checkouts[info.root]?.branch : undefined);
  const actionsButton = useRef<HTMLButtonElement>(null);
  const projectChat = !!info.projectID && !info.chats;
  const terminal = projectChat && showingTerminal;
  const actionsAvailable = projectChat && !showingReview && !showingTerminal;

  const title = terminal ? `${info.projectName ?? "Octo"} · Terminal` : info.threadTitle ?? "Welcome to Octo";
  const subtitle = terminal ? "Project terminal workspace"
    : info.chats ? "Chats"
    : [info.projectName ?? "Local development", info.harness && harnessTitle(info.harness), branch || undefined].filter(Boolean).join(" · ");

  return (
    <header className={styles.titlebar} data-testid="workspace-titlebar" style={{ paddingLeft: showSidebarToggle ? 92 : 16 }}>
      {showSidebarToggle && (
        <div className={styles.titlebarLeading}>
          <CornerButton aria-label="Show sidebar" help="Show sidebar (⌘B)" onClick={toggleSidebar}><PanelLeft size={15} /><ShortcutHint command="sidebar" /></CornerButton>
          <CornerButton aria-label="Search all chats" help="Search all chats (⌘K)" onClick={() => useUI.setState({ palette: "chats" })}><Search size={14} /></CornerButton>
        </div>
      )}
      <div className={styles.title}>
        <strong>{title}</strong>
        <span>{subtitle}</span>
      </div>
      <span className={styles.spacer} />
      {projectChat && (
        <div className={styles.toolbarCapsule} role="group" aria-label="Thread surfaces">
          {terminal
            ? <ToolbarButton aria-label="Back to thread" help="Back to thread (⌘J)" onClick={() => useUI.getState().focusComposer()}><MessageSquare size={15} /><ShortcutHint command="terminal" /></ToolbarButton>
            : <ToolbarButton aria-label="Terminal" help="Terminal (⌘J)" onClick={() => { if (info.projectID) openTerminal(info.projectID); }}><SquareTerminal size={15} /><ShortcutHint command="terminal" placement="leading" /></ToolbarButton>}
          {actionsAvailable && !projectActionsFloat && (
            <ToolbarButton ref={actionsButton} aria-label="Project actions" help="Open in, branches and changes" active={projectActions}
              onClick={() => useUI.setState({ projectActions: !projectActions })}><GitBranchIcon size={15} /></ToolbarButton>
          )}
          {!terminal && (
            <ToolbarButton aria-label={showingReview ? "Hide review panel" : "Show review panel"} help={showingReview ? "Hide review panel (⌥⌘B)" : "Show review panel (⌥⌘B)"}
              active={showingReview} onClick={toggleReview}><PanelRight size={15} /><ShortcutHint command="review" /></ToolbarButton>
          )}
        </div>
      )}
      {projectActions && actionsAvailable && !projectActionsFloat && (
        <Popover anchor={actionsButton} label="Project actions" close={() => useUI.setState({ projectActions: false })}>
          <ProjectActions floating={false} />
        </Popover>
      )}
    </header>
  );
}
