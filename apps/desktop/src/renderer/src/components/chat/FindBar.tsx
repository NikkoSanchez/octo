import { useEffect, useRef, useState } from "react";
import { ChevronDown, ChevronUp, Search, X } from "lucide-react";
import { ThreadFind, type ChatMessage } from "@octo/core";
import { useUI } from "../../state/ui";
import { ToolbarButton } from "../controls";
import type { FindResults } from "./Transcript";
import styles from "./chat.module.css";

/**
 * ⌘F's bar: a glass capsule floating over the top of the transcript. It is mounted only while find
 * is open, so it takes focus as it appears. Searching waits for a pause in typing; streamed text re-searches.
 */
export function FindBar({ messages, results, setResults, matchIndex, step, close }: {
  messages: ChatMessage[];
  results: FindResults;
  setResults: (results: FindResults) => void;
  matchIndex: number;
  step: (delta: number) => void;
  close: () => void;
}) {
  const [query, setQuery] = useState(results.query);
  const focus = useUI((s) => s.findFocus);
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => { field.current?.focus(); field.current?.select(); }, [focus]);

  const tail = messages.at(-1)?.text.length ?? 0;
  useEffect(() => {
    if (!query.trim()) { setResults({ query, ids: [] }); return; }
    const timer = setTimeout(() => setResults({ query, ids: ThreadFind.matches(query, messages) }), 120);
    return () => clearTimeout(timer);
    // Re-search when messages arrive or the last one grows, not on every unrelated render.
  }, [query, messages.length, tail]);

  const status = !results.query ? "" : !results.ids.length ? "No matches"
    : `${Math.min(matchIndex + 1, results.ids.length)} of ${results.ids.length} ${results.ids.length === 1 ? "message" : "messages"}`;
  return (
    <div className={styles.findBarFrame}>
      <div className={styles.findBar}>
        <Search size={13} strokeWidth={2.2} className={styles.findIcon} />
        <input ref={field} data-plain aria-label="Find in this thread" placeholder="Find in this thread" value={query} onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") { e.preventDefault(); close(); }
            else if (e.key === "Enter" || e.key === "ArrowDown") { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
            else if (e.key === "ArrowUp") { e.preventDefault(); step(-1); }
          }} />
        <span className={styles.findStatus} aria-live="polite">{status}</span>
        <ToolbarButton aria-label="Previous match" help="Previous match (⇧⌘G)" disabled={!results.ids.length} onClick={() => step(-1)}><ChevronUp size={14} /></ToolbarButton>
        <ToolbarButton aria-label="Next match" help="Next match (⌘G)" disabled={!results.ids.length} onClick={() => step(1)}><ChevronDown size={14} /></ToolbarButton>
        <ToolbarButton aria-label="Close search" help="Close search (Escape)" onClick={close}><X size={14} /></ToolbarButton>
      </div>
    </div>
  );
}
