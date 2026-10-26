import { memo, useEffect, useRef, useState, type CSSProperties, type MouseEvent } from "react";
import { createPortal } from "react-dom";
import { Folder, Pin } from "lucide-react";
import { harnessTitle } from "@octo/core";
import { sidebarAge, sidebarTimestamp, type SidebarThread } from "../../lib/sidebar";
import { contextMenu, type MenuSpec } from "../../lib/menu";
import { deepEqual } from "../../lib/equality";
import { run } from "../../bridge";
import { cx, ThreadAvatar, TypingIndicator } from "../controls";
import styles from "./sidebar.module.css";

/** Like a tooltip: passing over rows must not open a card for each one. */
const HOVER_CARD_DELAY = 450;
/** Rows scroll beneath a still pointer; hover is ignored until scrolling settles. */
let lastScroll = 0;
export function noteSidebarScroll(): void { lastScroll = performance.now(); }
const scrolling = () => performance.now() - lastScroll < 200;

/**
 * A conversation row after Messages: unread dot, provider avatar (ringed while working), title
 * with its last activity, then the latest reply or typing dots. Where rows from several projects
 * mix, the second line leads with the project.
 */
export const ThreadRow = memo(function ThreadRow({ thread, selected, highlighted = false, showsProjectName = false, snippet, open, menu }: {
  thread: SidebarThread;
  selected: boolean;
  /** The keyboard's place in search results, drawn like a hover. */
  highlighted?: boolean;
  showsProjectName?: boolean;
  /** The matching message, in search results. */
  snippet?: string;
  open: (thread: SidebarThread) => void;
  menu: (thread: SidebarThread) => MenuSpec[];
}) {
  const [hovering, setHovering] = useState(false);
  const [card, setCard] = useState<DOMRect>();
  const [marquee, setMarquee] = useState<CSSProperties>();
  const rowRef = useRef<HTMLDivElement>(null), titleRef = useRef<HTMLSpanElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);

  const leave = () => { clearTimeout(timer.current); setHovering(false); setCard(undefined); setMarquee(undefined); };
  const enter = () => {
    if (scrolling() || hovering) return;
    setHovering(true);
    // A long title scrolls once to its end, then stays there while hovered.
    const title = titleRef.current, overflow = title ? title.scrollWidth - title.clientWidth : 0;
    if (overflow > 1) setMarquee({ "--overflow": `${-overflow}px`, "--duration": `${1 + overflow / 30}s` } as CSSProperties);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => { if (document.hasFocus() && rowRef.current) setCard(rowRef.current.getBoundingClientRect()); }, HOVER_CARD_DELAY);
  };
  useEffect(() => {
    if (!card) return;
    const dismiss = () => setCard(undefined);
    window.addEventListener("pointerdown", dismiss, true);
    window.addEventListener("keydown", dismiss, true);
    window.addEventListener("wheel", dismiss, true);
    window.addEventListener("blur", dismiss);
    return () => {
      window.removeEventListener("pointerdown", dismiss, true);
      window.removeEventListener("keydown", dismiss, true);
      window.removeEventListener("wheel", dismiss, true);
      window.removeEventListener("blur", dismiss);
    };
  }, [card]);
  useEffect(() => () => clearTimeout(timer.current), []);

  const line = thread.running ? "Working" : snippet ?? thread.preview ?? "No messages yet";
  const togglePin = (event: MouseEvent) => { event.stopPropagation(); run("store", "toggleThreadPin", thread.id); };

  return (
    <div ref={rowRef} className={cx(styles.threadRow, selected && styles.selected, highlighted && !selected && styles.highlighted)}
      onPointerEnter={enter} onPointerMove={enter} onPointerLeave={leave} onContextMenu={contextMenu(() => menu(thread))}>
      <button type="button" className={styles.threadButton} aria-current={selected ? "page" : undefined}
        aria-label={`${thread.title}, ${thread.projectName}`} aria-description={thread.running ? "Working" : thread.unread ? "Finished, unread" : "Read"}
        onClick={() => open(thread)}>
        <span className={cx(styles.unreadDot, thread.unread && styles.unread)} />
        <span title={harnessTitle(thread.harness)}><ThreadAvatar harness={thread.harness} size={36} running={thread.running} outline={selected ? "var(--row-selection)" : undefined} /></span>
        <span className={styles.threadText}>
          <span className={styles.threadTitleLine}>
            <span ref={titleRef} className={styles.threadTitle}>
              <span className={cx(marquee && styles.marquee)} style={marquee}>{thread.title}</span>
            </span>
            <time className={styles.timestamp} style={{ opacity: hovering ? 0 : 1 }}>{sidebarTimestamp(thread.activityAt)}</time>
          </span>
          <span className={styles.preview}>
            {thread.running && <TypingIndicator />}
            <span className={styles.previewText}>{showsProjectName ? <><b>{thread.projectName}</b> · {line}</> : line}</span>
          </span>
        </span>
      </button>
      <button type="button" className={cx(styles.pin, (hovering || highlighted) && styles.pinShown, thread.pinned && styles.pinned)}
        title={thread.pinned ? "Unpin thread" : "Pin thread"} aria-label={`${thread.pinned ? "Unpin" : "Pin"} ${thread.title}`} onClick={togglePin}>
        <Pin size={12} fill={thread.pinned ? "currentColor" : "none"} />
      </button>
      {card && createPortal(<HoverCard thread={thread} anchor={card} />, document.body)}
    </div>
  );
}, (a, b) => a.selected === b.selected && a.highlighted === b.highlighted && a.showsProjectName === b.showsProjectName && a.snippet === b.snippet
  && a.open === b.open && a.menu === b.menu && deepEqual(a.thread, b.thread));

function HoverCard({ thread, anchor }: { thread: SidebarThread; anchor: DOMRect }) {
  const left = Math.min(anchor.right + 8, window.innerWidth - 328);
  const top = Math.max(8, Math.min(anchor.top + anchor.height / 2 - 40, window.innerHeight - 96));
  return (
    <div className={styles.hoverCard} style={{ left, top }} aria-hidden="true">
      <div className={styles.hoverTitle}><strong>{thread.title}</strong><time>{sidebarAge(thread.activityAt)}</time></div>
      <div className={styles.hoverProject}><Folder size={14} />{thread.projectName}</div>
    </div>
  );
}

/** An inset hairline aligned with the row text, after Messages; hidden beside the selected row. */
export function SidebarSeparator({ hidden }: { hidden: boolean }) {
  return <div className={styles.separator} style={{ opacity: hidden ? 0 : 1 }} aria-hidden="true" />;
}
