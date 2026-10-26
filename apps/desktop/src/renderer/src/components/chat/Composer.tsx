import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ArrowUp, Braces, ListPlus, MousePointerClick, Plus, RefreshCw, Square, X } from "lucide-react";
import { annotationLabel, annotationPromptContext, attachmentLabel, attachmentPromptContext, durationLabel, harnessTitle, MarkdownListEditing } from "@octo/core";
import { isProjectChat, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { insertCommand, slashToken } from "../../lib/slashCommands";
import { call, run } from "../../bridge";
import { BorderedButton, cx, HoverButton, PrimaryButton, Spinner, WorkingIndicator } from "../controls";
import { AgentControls } from "./AgentControls";
import { ContextUsage } from "./ContextUsage";
import { ImageStrip } from "./Transcript";
import styles from "./chat.module.css";

/** The composer starts at two lines, grows with its content up to this height, then scrolls. */
const MIN_HEIGHT = 44, MAX_HEIGHT = 220;

export function Composer({ threadID }: { threadID: string }) {
  const thread = useApp((s) => {
    const t = s.archive.projects.flatMap((p) => p.threads).find((candidate) => candidate.id === threadID);
    return { harness: t?.harness ?? "codex", directory: t?.workingDirectory ?? "", model: t?.agentSettings.model, usage: t?.conversationUsage, compaction: t?.lastCompaction };
  });
  const data = useApp((s) => {
    const key = `${thread.harness}:${thread.directory}`;
    const descriptor = s.descriptors.find((d) => d.id === thread.harness);
    return {
      running: s.running.includes(threadID), stopping: s.stopping.includes(threadID), canSave: s.canSave, projectChat: isProjectChat(s),
      draft: s.drafts[threadID], importing: s.importingImages.includes(threadID), descriptor,
      catalog: s.modelCatalogs[key], modelError: s.modelErrors[key], claudeSignedOut: thread.harness === "claude" && s.claudeAuth?.loggedIn === false,
    };
  });
  const text = useUI((s) => s.drafts[threadID] ?? "");
  const sendRequest = useUI((s) => s.sendRequest);
  const [sending, setSending] = useState(false);

  const images = data.draft?.images ?? [];
  const canAddImages = !!data.descriptor?.supportsImages && !data.importing && images.length < 4;
  const canSend = data.canSave && !data.importing && !sending && (!!text.trim() || images.length > 0);

  const send = async () => {
    if (!canSend) return;
    setSending(true);
    const snapshot = text;
    try {
      // Main takes the draft's attachments; the text clears unless it changed while sending.
      if (await call("store", "send", threadID, snapshot) && useUI.getState().drafts[threadID] === snapshot) setDraft(threadID, "");
    } catch (error) { useUI.getState().showError(String(error instanceof Error ? error.message : error)); }
    finally { setSending(false); }
  };
  const sendRef = useRef(send);
  sendRef.current = send;
  const handledSend = useRef(sendRequest);
  useEffect(() => {
    if (sendRequest === handledSend.current) return;
    handledSend.current = sendRequest;
    void sendRef.current();
  }, [sendRequest]);

  const savedModelUnavailable = !!data.descriptor?.supportsModels && !!thread.model && !!data.catalog && !data.catalog.some((m) => m.model === thread.model);
  return (
    <div className={styles.composerFrame}>
      <div className={styles.composer}>
        <QueuedMessages threadID={threadID} />
        {data.draft?.code.map((attachment) => (
          <div key={attachment.id} className={cx(styles.draftChip, styles.codeChip)} title={attachmentPromptContext(attachment)}>
            <Braces size={14} /><span>{attachmentLabel(attachment)}</span>
            <HoverButton aria-label="Remove attachment" help="Remove attachment" onClick={() => run("store", "removeDraftCode", threadID, attachment.id)}><X size={13} /></HoverButton>
          </div>
        ))}
        {data.draft?.annotations.map((annotation) => (
          // The tooltip shows exactly what will be sent with the message.
          <div key={annotation.id} className={cx(styles.draftChip, styles.annotationChip)} title={annotationPromptContext(annotation)}>
            <MousePointerClick size={14} /><span>{annotationLabel(annotation)}</span>
            <HoverButton aria-label="Remove annotation" help="Remove annotation" onClick={() => run("store", "removeDraftAnnotation", threadID, annotation.id)}><X size={13} /></HoverButton>
          </div>
        ))}
        {images.length > 0 && <ImageStrip images={images} remove={(id) => run("store", "removeDraftImage", threadID, id)} />}
        {thread.compaction?.state === "compacting" && <Compacting startedAt={thread.compaction.startedAt} />}
        <DraftEditor threadID={threadID} text={text} running={data.running} projectChat={data.projectChat} disabled={!data.canSave} onSend={() => void send()} />
        <div className={styles.controls}>
          <HoverButton aria-label="Add images" help={data.descriptor?.supportsImages ? "Add images" : "Images are unavailable with this provider"}
            disabled={!canAddImages} onClick={() => run("store", "chooseImages", threadID)}><Plus size={16} /></HoverButton>
          {data.importing && <Spinner label="Loading images" />}
          <AgentControls threadID={threadID} />
          <span className={styles.spacer} />
          <ContextUsage usage={thread.usage} compaction={thread.compaction} provider={harnessTitle(thread.harness)}
            supportsUsage={!!data.descriptor?.supportsConversationUsage} supportsCompaction={!!data.descriptor?.supportsCompactionStatus} />
          {data.running && (
            <BorderedButton aria-label="Stop" help="Stop the agent (⌘.)" disabled={data.stopping} onClick={() => run("store", "stop", threadID)}><Square size={11} fill="currentColor" /></BorderedButton>
          )}
          <PrimaryButton aria-label={data.running ? "Queue message" : "Send message"} help={data.running ? "Queue message (Return)" : "Send message (Return)"}
            disabled={!canSend} onClick={() => void send()}>
            {data.running ? <ListPlus size={15} /> : <ArrowUp size={15} strokeWidth={2.5} />}
          </PrimaryButton>
        </div>
        {data.modelError && <small className={styles.notice2}>{data.modelError}</small>}
        {!data.modelError && savedModelUnavailable && <small className={styles.notice2}>The saved model is unavailable. Choose another in Agent settings.</small>}
        {data.claudeSignedOut && <small className={styles.notice2}>Claude is signed out. Open Settings → Agents → Open CLI sign-in.</small>}
        {!data.descriptor?.executable && <small className={styles.notice2}>{harnessTitle(thread.harness)} CLI was not found. Install it, or choose an installation in Settings → Agents.</small>}
      </div>
    </div>
  );
}

function setDraft(threadID: string, value: string): void {
  useUI.getState().setDraft(threadID, value);
  run("store", "setDraftReady", threadID, !!value.trim());
}

function Compacting({ startedAt }: { startedAt: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  return (
    <div className={styles.compacting}>
      <WorkingIndicator icon={<RefreshCw size={12} />} /><span>Compacting context…</span><span className={styles.spacer} /><span>{durationLabel((now - startedAt) / 1000)}</span>
    </div>
  );
}

/**
 * Plain-text editing with Return to send. Shift–Return inserts a line, continuing a Markdown list;
 * Tab nests a list item and otherwise moves to the next control. IME composition never sends.
 * Typing `/` lists the provider's skills and commands; choosing one inserts it without sending.
 */
function DraftEditor({ threadID, text, running, projectChat, disabled, onSend }: {
  threadID: string; text: string; running: boolean; projectChat: boolean; disabled: boolean; onSend: () => void;
}) {
  const focusRequest = useUI((s) => s.composerFocus);
  const commands = useApp((s) => {
    const thread = s.archive.projects.flatMap((p) => p.threads).find((t) => t.id === threadID);
    const key = thread ? `${thread.harness}:${thread.workingDirectory}` : "";
    return { list: s.commandCatalogs[key], loading: s.loadingCommands.includes(key), error: s.commandErrors[key], provider: thread ? harnessTitle(thread.harness) : "" };
  });
  const editor = useRef<HTMLTextAreaElement>(null);
  const composing = useRef(false);
  const [caret, setCaret] = useState<number>();
  const [selected, setSelected] = useState(0);
  const [dismissed, setDismissed] = useState<string>();
  const pendingCaret = useRef<number>(undefined);

  const token = slashToken(text, caret ?? text.length);
  const showing = !!token && dismissed !== text;
  const matching = token ? (commands.list ?? []).filter((c) => c.name.toLowerCase().startsWith(token.query.toLowerCase())) : [];
  const index = Math.min(selected, Math.max(0, matching.length - 1));

  useLayoutEffect(() => {
    const node = editor.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, node.scrollHeight))}px`;
    if (pendingCaret.current !== undefined) { node.setSelectionRange(pendingCaret.current, pendingCaret.current); setCaret(pendingCaret.current); pendingCaret.current = undefined; }
  }, [text]);
  useEffect(() => { editor.current?.focus(); }, [focusRequest, threadID]);
  useEffect(() => { setSelected(0); setDismissed(undefined); }, [text]);
  useEffect(() => { document.getElementById(`slash-${index}`)?.scrollIntoView({ block: "nearest" }); }, [index]);

  const edit = (value: string, caretAt?: number) => { pendingCaret.current = caretAt; setDraft(threadID, value); };
  const choose = (command: (typeof matching)[number]) => {
    if (!token) return;
    const result = insertCommand(text, token, command);
    edit(result.text, result.caret);
  };

  return (
    <>
      {showing && (
        <div className={styles.commands}>
          <div className={styles.commandsHeader}>
            <strong>Skills &amp; commands</strong>
            <button type="button" disabled={commands.loading} onMouseDown={(e) => e.preventDefault()} onClick={() => run("store", "loadCommands", threadID, true)}>Refresh</button>
          </div>
          {commands.loading ? <small>Loading from {commands.provider}…</small>
            : commands.error ? <small>{commands.error}</small>
            : !matching.length ? <small>No matching commands reported by this CLI. Check your provider’s skills and this chat’s working directory.</small>
            : <>
                <div className={styles.commandList} role="listbox" id="slash-commands" aria-label="Skills and commands">
                  {matching.map((command, i) => (
                    <button key={command.name} id={`slash-${i}`} type="button" role="option" aria-selected={i === index} aria-label={`Insert /${command.name}`}
                      className={cx(styles.command, i === index && styles.commandSelected)} onMouseDown={(e) => e.preventDefault()} onClick={() => choose(command)}>
                      <strong>/{command.name} {command.argumentHint}</strong>
                      {command.description && <span>{command.description}</span>}
                    </button>
                  ))}
                </div>
                <small>↑ ↓ to choose · Return or Tab to insert · Escape to dismiss</small>
              </>}
        </div>
      )}
      <textarea ref={editor} className={styles.editor} aria-label="Message" rows={2} value={text} disabled={disabled} spellCheck
        placeholder={running ? "Add a follow-up…" : projectChat ? "Ask about this project…" : "Ask anything…"}
        aria-controls={showing ? "slash-commands" : undefined} aria-activedescendant={showing && matching.length ? `slash-${index}` : undefined}
        onChange={(e) => { setDraft(threadID, e.target.value); setCaret(e.target.selectionStart); }}
        onSelect={(e) => setCaret(e.currentTarget.selectionStart === e.currentTarget.selectionEnd ? e.currentTarget.selectionStart : undefined)}
        onCompositionStart={() => { composing.current = true; }}
        onCompositionEnd={() => { composing.current = false; }}
        onPaste={(e) => {
          // A screenshot attaches as an image instead of inserting rich content.
          if ([...e.clipboardData.items].some((item) => item.type.startsWith("image/"))) { e.preventDefault(); run("store", "pasteImage", threadID); }
        }}
        onKeyDown={(e) => {
          if (composing.current || e.nativeEvent.isComposing || e.nativeEvent.keyCode === 229) return;
          const plain = !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;
          if (showing && plain) {
            if (e.key === "Escape") { e.preventDefault(); setDismissed(text); return; }
            if (matching.length && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
              e.preventDefault(); setSelected((index + (e.key === "ArrowDown" ? 1 : matching.length - 1)) % matching.length); return;
            }
            if (matching.length && (e.key === "Enter" || e.key === "Tab")) { e.preventDefault(); choose(matching[index]); return; }
          }
          const node = e.currentTarget, selection = { location: node.selectionStart, length: node.selectionEnd - node.selectionStart };
          if (e.key === "Enter" && e.shiftKey && !e.metaKey && !e.altKey) {
            const listEdit = MarkdownListEditing.newline(text, selection);
            if (listEdit) { e.preventDefault(); edit(MarkdownListEditing.apply(text, listEdit), listEdit.selection.location); }
            return;
          }
          if (e.key === "Enter" && !e.altKey && !e.ctrlKey) {
            e.preventDefault();
            if (!e.repeat) onSend();
            return;
          }
          // In a list Tab nests the item; elsewhere it moves focus, as in a form.
          if (e.key === "Tab" && !e.metaKey && !e.altKey && MarkdownListEditing.isInList(text, selection)) {
            e.preventDefault();
            const listEdit = (e.shiftKey ? MarkdownListEditing.outdent : MarkdownListEditing.indent)(text, selection);
            if (listEdit) edit(MarkdownListEditing.apply(text, listEdit), listEdit.selection.location);
          }
        }} />
    </>
  );
}

function QueuedMessages({ threadID }: { threadID: string }) {
  const data = useApp((s) => ({
    queued: s.queued[threadID], running: s.running.includes(threadID), stopping: s.stopping.includes(threadID), paused: s.pausedQueues.includes(threadID),
    steering: s.steering[threadID], errors: s.queueErrors,
    canSteer: s.descriptors.find((d) => d.id === s.archive.projects.flatMap((p) => p.threads).find((t) => t.id === threadID)?.harness)?.capabilities.steering === true,
  }));
  if (!data.queued?.length) return null;
  return (
    <div className={styles.queue}>
      <div className={styles.queueHeader}>
        <strong>Queued · {data.queued.length}</strong>
        <span className={styles.spacer} />
        {!data.running && <BorderedButton small disabled={!!data.steering} onClick={() => run("store", "resumeQueue", threadID)}>Send queued</BorderedButton>}
      </div>
      <div className={styles.queueList} style={{ maxHeight: Math.min(data.queued.length * 72, 144) }}>
        {data.queued.map((queued) => {
          const message = queued.message;
          return (
            <div key={queued.id} className={styles.queued}>
              <div className={styles.queuedText}>
                <span title={message.text}>{message.text || "Image message"}</span>
                {(message.images.length > 0 || message.attachments.length > 0 || message.browserAnnotations.length > 0) && (
                  <small>{message.images.length} images · {message.attachments.length} code selections{message.browserAnnotations.length ? ` · ${message.browserAnnotations.length} annotations` : ""}</small>
                )}
                {data.errors[queued.id] && <small className={styles.errorText}>{data.errors[queued.id]}</small>}
              </div>
              {data.steering === queued.id ? <Spinner label="Sending steering message" /> : <>
                {data.running && data.canSteer && (
                  <BorderedButton small disabled={!!data.steering || data.stopping} onClick={() => run("store", "steerQueued", queued.id, threadID)}>Steer now</BorderedButton>
                )}
                <HoverButton aria-label="Remove queued message" help="Remove queued message" onClick={() => run("store", "removeQueued", queued.id, threadID)}><X size={13} /></HoverButton>
              </>}
            </div>
          );
        })}
      </div>
      <small>{data.paused ? "Queue paused. Messages are kept here until you send them." : "Sends in order after the current turn. Queued messages stay here until you quit."}</small>
    </div>
  );
}
