import { fold, foldQuery, unfoldRange } from "./text";
import type { ChatMessage, MessageRole } from "./workspace";

/**
 * Find in the current thread (⌘F). It searches the messages shown in the transcript (the user's,
 * the agent's replies and errors), not the collapsed activity and reasoning, so every match can
 * be scrolled to and highlighted where it is read.
 */
export const ThreadFind = {
  isSearchable(role: MessageRole): boolean {
    return role === "user" || role === "assistant" || role === "error";
  },

  /** The searchable messages containing `query`, in transcript order. Blank queries match nothing. */
  matches(query: string, messages: ChatMessage[]): string[] {
    const needle = foldQuery(query.trim());
    if (!needle) return [];
    return messages.filter((m) => ThreadFind.isSearchable(m.role) && fold(m.text).text.includes(needle)).map((m) => m.id);
  },

  /** Every occurrence of `query` in `text` as UTF-16 `[start, end)` pairs, for highlighting. */
  ranges(query: string, text: string): [number, number][] {
    const needle = foldQuery(query.trim());
    if (!needle) return [];
    const folded = fold(text);
    const result: [number, number][] = [];
    let start = 0;
    while (start < folded.text.length) {
      const found = folded.text.indexOf(needle, start);
      if (found === -1) break;
      result.push(unfoldRange(folded, found, found + needle.length));
      start = found + needle.length;
    }
    return result;
  },
};
