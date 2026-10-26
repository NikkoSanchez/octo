import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowDown, Hand, MessageSquare } from "lucide-react";
import { isProjectChat, selectedThread, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { newThread } from "../../lib/workspace";
import { run } from "../../bridge";
import { BorderedButton, EmptyState, PrimaryButton, WorkingIndicator } from "../controls";
import { Composer } from "./Composer";
import { FindBar } from "./FindBar";
import { InteractionCard } from "./InteractionCard";
import { Transcript, type FindResults } from "./Transcript";
import { useTranscriptScroll } from "./useTranscriptScroll";
import styles from "./chat.module.css";

/** The conversation column: at most 840 pt wide, centred. */
export function ChatPane({ visible }: { visible: boolean }) {
  const threadID = useApp((s) => selectedThread(s)?.id);
  if (!threadID) {
    return (
      <div className={styles.chat}>
        <EmptyState icon={<MessageSquare size={32} strokeWidth={1.4} />} title="Start a chat">
          <PrimaryButton onClick={() => newThread()}>New Chat</PrimaryButton>
        </EmptyState>
      </div>
    );
  }
  return <ThreadChat key={threadID} threadID={threadID} visible={visible} />;
}

function ThreadChat({ threadID, visible }: { threadID: string; visible: boolean }) {
  const thread = useApp((s) => {
    const t = selectedThread(s);
    return { messages: t?.messages ?? [], harness: t?.harness ?? "codex", directory: t?.workingDirectory ?? "", unreadCompletedAt: t?.unreadCompletedAt };
  });
  const info = useApp((s) => ({
    running: s.running.includes(threadID), projectChat: isProjectChat(s),
    approvals: s.approvals[threadID], interactions: s.interactions[threadID], queued: s.queued[threadID]?.length ?? 0,
    installed: s.descriptors.filter((d) => d.executable).map((d) => d.id).join(","),
  }));
  const finding = useUI((s) => s.findingThread);
  const showingTerminal = useUI((s) => s.showingTerminal);
  const findStep = useUI((s) => s.findStep);
  const [results, setResults] = useState<FindResults>({ query: "", ids: [] });
  const [matchIndex, setMatchIndex] = useState(0);
  const [expanded, setExpandedSet] = useState<Set<string>>(new Set());
  const [windowFocused, setWindowFocused] = useState(document.hasFocus());
  const { scroller, content, following, resume } = useTranscriptScroll(threadID, !visible || showingTerminal, finding);

  const setExpanded = useCallback((id: string, open: boolean) => setExpandedSet((current) => {
    const next = new Set(current);
    if (open) next.add(id); else next.delete(id);
    return next;
  }), []);
  const find = finding ? results : { query: "", ids: [] };
  const scrollToMatch = useCallback((index: number, ids: string[]) => {
    const id = ids[index];
    if (id) document.getElementById(`message-${id}`)?.scrollIntoView({ block: "center" });
  }, []);
  const step = useCallback((delta: number) => {
    if (!results.ids.length) return;
    const next = (matchIndex + delta + results.ids.length) % results.ids.length;
    setMatchIndex(next);
    scrollToMatch(next, results.ids);
  }, [matchIndex, results.ids, scrollToMatch]);
  const resultsRef = useRef(results);
  resultsRef.current = results;
  const updateResults = useCallback((next: FindResults) => {
    const previous = resultsRef.current;
    setResults(next);
    // A new query starts at its first match; streamed text keeps the current one.
    if (previous.query !== next.query) { setMatchIndex(0); requestAnimationFrame(() => scrollToMatch(0, next.ids)); }
    else setMatchIndex((index) => Math.min(index, Math.max(0, next.ids.length - 1)));
  }, [scrollToMatch]);
  // ⌘G and ⇧⌘G arrive as requests from the command router.
  const stepRef = useRef(step);
  stepRef.current = step;
  useEffect(() => { if (findStep.request) stepRef.current(findStep.delta); }, [findStep]);
  const closeFind = () => { useUI.setState({ findingThread: false }); setResults({ query: "", ids: [] }); useUI.getState().focusComposer(); };

  // A finished reply counts as read once it is visible in a focused window and followed to its end.
  useEffect(() => {
    const focus = () => setWindowFocused(document.hasFocus());
    window.addEventListener("focus", focus); window.addEventListener("blur", focus);
    return () => { window.removeEventListener("focus", focus); window.removeEventListener("blur", focus); };
  }, []);
  const readable = visible && windowFocused && following && !finding;
  useEffect(() => { if (readable) run("store", "markThreadRead", threadID); }, [readable, threadID, thread.unreadCompletedAt]);

  // The agent menu lists every installed provider's models. Discovery only initializes each CLI; it never starts a model turn.
  useEffect(() => {
    if (thread.harness === "codex") run("store", "refreshCodexVersion");
    run("store", "loadModels", thread.directory, thread.harness);
    for (const id of info.installed.split(",").filter(Boolean)) if (id !== thread.harness) run("store", "loadModels", thread.directory, id as typeof thread.harness);
    run("store", "loadCommands", threadID);
  }, [thread.harness, thread.directory, info.installed, threadID]);

  return (
    <div className={styles.chat}>
      <div className={styles.transcriptFrame}>
        <div ref={scroller} className={styles.transcript} data-testid="transcript" tabIndex={-1}>
          <div ref={content}>
            <Transcript messages={thread.messages} active={info.running} projectChat={info.projectChat} find={find} matchIndex={matchIndex}
              expanded={expanded} setExpanded={setExpanded} />
          </div>
        </div>
        {finding && <FindBar messages={thread.messages} results={results} setResults={updateResults} matchIndex={matchIndex} step={step} close={closeFind} />}
        {!following && !finding && (
          <button type="button" className={styles.followPill} title="Scroll to the latest message and follow new output" onClick={resume}
            aria-label={info.running ? "Working · Scroll to end" : "Scroll to end"}>
            {info.running ? <WorkingIndicator /> : <ArrowDown size={13} />}
            {info.running ? "Working · Scroll to end" : "Scroll to end"}
          </button>
        )}
      </div>
      {info.approvals?.map((approval) => (
        <section key={approval.id} className={styles.approval} aria-label={approval.title}>
          <h3><Hand size={15} />{approval.title}</h3>
          <pre>{approval.detail}</pre>
          <div className={styles.actions}>
            <BorderedButton onClick={() => run("store", "answer", approval.id, threadID, false)}>Decline</BorderedButton>
            <PrimaryButton onClick={() => run("store", "answer", approval.id, threadID, true)}>Allow Once</PrimaryButton>
          </div>
        </section>
      ))}
      {!!info.interactions?.length && (
        <div className={styles.interactions} style={{ maxHeight: info.queued ? 180 : 340 }}>
          {info.interactions.map((request) => <InteractionCard key={request.id} request={request} threadID={threadID} />)}
        </div>
      )}
      <Composer threadID={threadID} />
    </div>
  );
}
