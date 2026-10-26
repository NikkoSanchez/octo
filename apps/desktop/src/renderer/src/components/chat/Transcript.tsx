import { memo, useEffect, useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Copy, MousePointerClick, Braces } from "lucide-react";
import {
  annotationLabel, annotationPromptContext, attachmentLabel, chatTurns, durationLabel, groupSummary, turnBody, turnLiveStatus, turnUser, turnWorkLabel,
  type ChatMessage, type ChatTurn, type ImageAttachment,
} from "@octo/core";
import { run } from "../../bridge";
import { cx, HoverButton, ShimmerText } from "../controls";
import { FindHighlightContext, Highlighted, Markdown } from "./Markdown";
import styles from "./chat.module.css";

export interface FindResults { query: string; ids: string[] }

/**
 * Every turn of the conversation. It compares its inputs, so publications that don't touch this
 * thread (sidebar changes, other threads streaming, model loading) skip rebuilding the turns.
 */
export const Transcript = memo(function Transcript({ messages, active, projectChat, find, matchIndex, expanded, setExpanded }: {
  messages: ChatMessage[];
  active: boolean;
  projectChat: boolean;
  find: FindResults;
  matchIndex: number;
  expanded: Set<string>;
  setExpanded: (id: string, expanded: boolean) => void;
}) {
  const turns = useMemo(() => chatTurns(messages), [messages]);
  const matches = useMemo(() => new Set(find.ids), [find.ids]);
  const current = find.ids[matchIndex];
  return (
    <div className={styles.turns}>
      {messages.length === 0 && (
        <div className={styles.welcome}>
          <h1>{projectChat ? "What are we building?" : "What's on your mind?"}</h1>
          <p>{projectChat
            ? "Start a conversation about this project. Select code in the review pane to attach precise context."
            : "Ask a question, explore an idea, or work through something. Your conversations live here in Chats."}</p>
        </div>
      )}
      {turns.map((turn, index) => (
        <Turn key={turn.id} turn={turn} active={active && index === turns.length - 1} matches={matches} query={find.query} current={current}
          expanded={expanded} setExpanded={setExpanded} />
      ))}
    </div>
  );
});

const Turn = memo(function Turn({ turn, active, matches, query, current, expanded, setExpanded }: {
  turn: ChatTurn; active: boolean; matches: Set<string>; query: string; current?: string;
  expanded: Set<string>; setExpanded: (id: string, expanded: boolean) => void;
}) {
  const user = turnUser(turn);
  const finalReply = turn.messages.findLast((m) => m.role === "assistant")?.id;
  const message = (m: ChatMessage, footer = true) => (
    <FindHighlightContext.Provider key={m.id} value={matches.has(m.id) ? { query, current: m.id === current } : undefined}>
      <MessageView message={m} footer={footer} current={m.id === current} />
    </FindHighlightContext.Provider>
  );
  return (
    <section className={styles.turn}>
      {user && message(user)}
      {turnBody(turn).map((group) => group.isDetails ? (
        // Find searches only what is shown, so it never expands activity.
        <div key={group.id} className={styles.work}>
          <HoverButton padded={false} className={styles.workToggle} aria-expanded={expanded.has(group.id)} aria-description="Show or hide reasoning and activity"
            onClick={() => setExpanded(group.id, !expanded.has(group.id))}>
            {expanded.has(group.id) ? <ChevronDown size={11} strokeWidth={2.5} /> : <ChevronRight size={11} strokeWidth={2.5} />}
            <span>{groupSummary(group.messages)}</span>
          </HoverButton>
          {expanded.has(group.id) && <div className={styles.workItems}>{group.messages.map((m) => message(m))}</div>}
        </div>
      ) : (
        // Updates between work are narration: only the turn's final reply reserves room for copy and time.
        group.messages.map((m) => message(m, m.role !== "assistant" || m.id === finalReply))
      ))}
      {/* The running turn ends with its live status; a finished turn keeps the same place for how long it took. */}
      {(active || user?.work) && (
        <div className={styles.workFooter}>
          {active ? <LiveStatus startedAt={user?.work?.startedAt} status={turnLiveStatus(turn)} /> : <span>{turnWorkLabel(user!.work!)}</span>}
          <hr />
        </div>
      )}
    </section>
  );
}, (a, b) => a.active === b.active && a.matches === b.matches && a.query === b.query && a.current === b.current
  && a.expanded === b.expanded && a.setExpanded === b.setExpanded
  // Turns are rebuilt on every streamed delta; settled messages keep their objects.
  && a.turn.messages.length === b.turn.messages.length && a.turn.messages.every((m, i) => m === b.turn.messages[i]));

function LiveStatus({ startedAt, status }: { startedAt?: number; status?: string }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  return (
    <span className={styles.live}>
      <ShimmerText>Working for {durationLabel((now - (startedAt ?? now)) / 1000)}</ShimmerText>
      {status && <span className={styles.liveStatus}>· {status}</span>}
    </span>
  );
}

const MessageView = memo(function MessageView({ message: m, footer, current }: { message: ChatMessage; footer: boolean; current: boolean }) {
  const user = m.role === "user";
  const date = m.completedAt ?? m.createdAt;
  return (
    <article id={`message-${m.id}`} className={cx(styles.message, user && styles.fromUser, current && styles.currentMatch)}>
      <div className={cx(styles.bubble, user && styles.userBubble)}>
        {m.role === "error" && <div className={styles.notice}>Agent notice</div>}
        {m.role === "assistant"
          ? <Markdown text={m.text} />
          : m.text && <div className={cx(styles.plainText, styles[m.role])}><Highlighted text={m.text} /></div>}
        {m.images.length > 0 && <ImageStrip images={m.images} />}
        {m.attachments.map((a) => <span key={a.id} className={cx(styles.chip, styles.codeChip)}><Braces size={12} />{attachmentLabel(a)}</span>)}
        {m.browserAnnotations.map((a) => <span key={a.id} className={cx(styles.chip, styles.annotationChip)} title={annotationPromptContext(a)}><MousePointerClick size={12} />{annotationLabel(a)}</span>)}
      </div>
      {footer && (user || m.role === "assistant" || m.role === "error") && (
        <footer className={styles.messageFooter}>
          {m.isSteering && <span>Steering message</span>}
          {/* Hover reveals copy and time without reflowing the response. */}
          <span className={styles.hoverDetails}>
            {m.role === "assistant" && (
              <HoverButton aria-label="Copy original response" help="Copy original response" onClick={() => run("app", "copyText", m.text)}><Copy size={12} /></HoverButton>
            )}
            <time dateTime={new Date(date).toISOString()} title={new Date(date).toLocaleString(undefined, { dateStyle: "full", timeStyle: "medium" })}>
              {new Date(date).toLocaleString(undefined, { weekday: "long", hour: "numeric", minute: "2-digit" })}
            </time>
          </span>
        </footer>
      )}
    </article>
  );
});

export function ImageStrip({ images, remove }: { images: ImageAttachment[]; remove?: (id: string) => void }) {
  return (
    <div className={styles.images}>
      {images.map((image) => (
        <figure key={image.id}>
          <img src={`data:image/png;base64,${image.pngBase64}`} alt={image.name} />
          <figcaption>
            <span>{image.name}</span>
            {remove && <button type="button" aria-label="Remove image" onClick={() => remove(image.id)}>×</button>}
          </figcaption>
        </figure>
      ))}
    </div>
  );
}
