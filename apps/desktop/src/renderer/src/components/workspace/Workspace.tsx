import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { FolderPlus } from "lucide-react";
import { useApp, useProject } from "../../state/app";
import { SINGLE_REVIEW_WIDTH, useCovered, useUI, workspaceLayout } from "../../state/ui";
import { run } from "../../bridge";
import { EmptyState, GlassPanel, PrimaryButton } from "../controls";
import { ResizeHandle } from "../ResizeHandle";
import { Sidebar } from "../sidebar/Sidebar";
import { ChatPane } from "../chat/ChatPane";
import { ProjectActions } from "../project/ProjectActions";
import { Overlays } from "../overlays/Overlays";
import { TITLEBAR_HEIGHT, Titlebar } from "./Titlebar";
import { useCheckoutRefresh, useKeyRouter, useMenuSync, useThemeApplication, useWindowWidth } from "./hooks";
import styles from "./workspace.module.css";

const TerminalWorkspace = lazy(() => import("../terminal/TerminalWorkspace"));
const ReviewPanel = lazy(() => import("../review/ReviewPanel"));

/** The chat column is at most this wide; the floating project card needs room beside it. */
const CHAT_WIDTH = 840, CARD_WIDTH = 260;

/**
 * The window, the sidebar card, then the detail area with the thread
 * (chat and review card) and the project's terminal workspace. Every surface stays mounted; hidden
 * ones move offscreen and leave the accessibility tree.
 */
export function Workspace() {
  useKeyRouter();
  useMenuSync();
  useCheckoutRefresh();
  useThemeApplication();
  const width = useWindowWidth();
  const ui = useUI(useShallow((s) => ({
    sidebarOpen: s.sidebarOpen, compactSidebarOpen: s.compactSidebarOpen, sidebarWidth: s.sidebarWidth,
    showingReview: s.showingReview, showingTerminal: s.showingTerminal,
  })));
  const project = useProject((p) => p && { id: p.id, chats: p.isChatCollection });
  const canSave = useApp((s) => s.canSave);
  const covered = useCovered();
  const layout = workspaceLayout(width, ui);

  const projectChat = !!project && !project.chats;
  const terminal = projectChat && ui.showingTerminal;
  const singleReview = projectChat && ui.showingReview && !ui.showingTerminal && layout.detailWidth < SINGLE_REVIEW_WIDTH;
  // Beside the chat, the review card runs the window's full height and the titlebar heads the chat
  // column. The terminal, the empty state and a review card covering the chat keep it above the whole detail area.
  const titlebarSpansDetail = !project || terminal || singleReview;
  const actionsAvailable = projectChat && !ui.showingReview && !ui.showingTerminal;
  const actionsFloat = (layout.detailWidth - CHAT_WIDTH) / 2 >= CARD_WIDTH + 32;

  useEffect(() => { useUI.setState({ compactSidebarOpen: false }); }, [layout.compact]);
  useEffect(() => { if (!actionsAvailable || actionsFloat) useUI.setState({ projectActions: false }); }, [actionsAvailable, actionsFloat, project?.id]);

  return (
    <div className={styles.workspace} data-testid="workspace">
      <div className={styles.detail} inert={layout.overlayVisible} style={{ left: layout.detailOffset, width: layout.detailWidth }}>
        {titlebarSpansDetail && <Titlebar showSidebarToggle={!layout.sidebarVisible} projectActionsFloat={actionsFloat} />}
        <div className={styles.content} style={{ top: titlebarSpansDetail ? TITLEBAR_HEIGHT : 0 }}>
          <div className={styles.surface} inert={terminal} aria-hidden={terminal} style={{ visibility: terminal ? "hidden" : undefined }}>
            {project
              ? <ThreadColumns detailWidth={layout.detailWidth} reviewVisible={projectChat && ui.showingReview && !ui.showingTerminal} single={singleReview}
                  titlebar={!titlebarSpansDetail && <Titlebar showSidebarToggle={!layout.sidebarVisible} projectActionsFloat={actionsFloat} />}
                  chatVisible={!terminal && !singleReview && !layout.overlayVisible && !covered} />
              : <EmptyState icon={<FolderPlus size={36} strokeWidth={1.4} />} title="A home for your projects"
                  description="Add a Git repository to start an agent thread, review changes, or open your terminal.">
                  <PrimaryButton onClick={() => run("store", "chooseProject")}>Add Project…</PrimaryButton>
                </EmptyState>}
            {actionsAvailable && actionsFloat && (
              // Below the chat column's titlebar, so it never covers the toolbar capsule.
              <div className={styles.floatingActions} style={{ top: (titlebarSpansDetail ? 0 : TITLEBAR_HEIGHT) + 16 }}>
                <ProjectActions floating />
              </div>
            )}
          </div>
          <Suspense fallback={null}>
            <TerminalWorkspace projectID={projectChat ? project.id : undefined} visible={terminal && !layout.overlayVisible && !covered} />
          </Suspense>
        </div>
        {!canSave && <div className={styles.storageWarning} role="status">The saved workspace could not be loaded. Saving is disabled for this launch.</div>}
      </div>
      {layout.overlayVisible && <button className={styles.scrim} aria-label="Close sidebar" onClick={() => useUI.setState({ compactSidebarOpen: false })} />}
      <div className={styles.sidebarFrame} inert={!layout.sidebarVisible} aria-hidden={!layout.sidebarVisible}
        style={{ width: layout.sidebarWidth, transform: layout.sidebarVisible ? "none" : `translateX(${-layout.sidebarWidth - 7}px)` }}>
        <Sidebar />
      </div>
      {layout.sidebarVisible && !layout.compact && (
        <SidebarResizer width={layout.sidebarWidth} />
      )}
      <Overlays />
    </div>
  );
}

function SidebarResizer({ width }: { width: number }) {
  const start = useRef(width);
  const setWidth = useUI((s) => s.setSidebarWidth);
  return (
    <ResizeHandle label="Resize sidebar" value={width} style={{ left: width, top: 0, bottom: 0 }}
      onDrag={(translation) => { if (translation === 0) start.current = width; setWidth(start.current + translation); }}
      onStep={(delta) => setWidth(width + delta)} />
  );
}

/**
 * The chat column beside the review card (300 pt chat minimum,
 * 430 pt card minimum, 42% initial share). Narrower than both, the card covers the chat.
 */
function ThreadColumns({ detailWidth, reviewVisible, single, titlebar, chatVisible }: {
  detailWidth: number; reviewVisible: boolean; single: boolean; titlebar: React.ReactNode; chatVisible: boolean;
}) {
  const projectChat = useProject((p) => !!p && !p.isChatCollection);
  const covered = useCovered();
  const [fraction, setFraction] = useState(0.42);
  const dragStart = useRef(0);
  const [reviewLoaded, setReviewLoaded] = useState(reviewVisible);
  useEffect(() => { if (reviewVisible) setReviewLoaded(true); }, [reviewVisible]);

  const available = Math.max(0, detailWidth - 7);
  const upper = Math.max(0, available - 430), lower = Math.min(300, upper);
  const chatWidth = Math.min(upper, Math.max(lower, available * fraction));
  const split = reviewVisible && !single;
  const setWidth = (next: number) => setFraction(Math.min(upper, Math.max(lower, next)) / Math.max(1, available));

  return (
    <div className={styles.columns}>
      <div className={styles.chatColumn} inert={single && reviewVisible} aria-hidden={single && reviewVisible}
        style={{ width: split ? chatWidth : "100%", visibility: single && reviewVisible ? "hidden" : undefined }}>
        {titlebar}
        <ChatPane visible={chatVisible} />
      </div>
      {split && (
        <ResizeHandle label="Resize panels" value={chatWidth} style={{ left: chatWidth, top: 0, bottom: 0 }}
          onDrag={(translation) => { if (translation === 0) dragStart.current = chatWidth; setWidth(dragStart.current + translation); }}
          onStep={(delta) => setWidth(chatWidth + delta)} />
      )}
      {projectChat && reviewLoaded && (
        // Level with the sidebar card beside the chat; under the titlebar when it covers the chat.
        <div className={styles.reviewFrame} inert={!reviewVisible} aria-hidden={!reviewVisible}
          style={{ left: split ? chatWidth + 7 : 0, paddingLeft: single ? 8 : 0, paddingTop: single ? 0 : 8, transform: reviewVisible ? "none" : "translateX(110vw)" }}>
          <GlassPanel className={styles.reviewCard}>
            <Suspense fallback={null}><ReviewPanel visible={reviewVisible && !covered} /></Suspense>
          </GlassPanel>
        </div>
      )}
    </div>
  );
}
