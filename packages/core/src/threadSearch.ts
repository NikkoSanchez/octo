import { escapeRegExp, fold, foldQuery, graphemes, unfoldRange } from "./text";
import { threadRecentAt, type RecentThread } from "./workspace";

/**
 * Chat search, as in the ⌘K palette: the query must appear as a phrase (ignoring case, accents and
 * runs of whitespace) in the title, the project name or one user/assistant message. Title matches
 * rank first, then the most recently active.
 */
export interface ThreadSearchResult {
  threadID: string;
  projectID: string;
  /** The newest matching message around its match, or undefined when the title or project name matched. */
  snippet?: string;
}

/** A query normalized once for repeated matching. */
export class SearchPhrase {
  private readonly text: string;
  /** The words separated by any run of whitespace, for text that wraps mid-phrase. */
  private readonly pattern?: RegExp;
  /** The longest word: text without it cannot match the pattern either. */
  private readonly longestWord: string;

  private constructor(words: string[]) {
    this.text = words.join(" ");
    this.longestWord = words.reduce((a, b) => (b.length > a.length ? b : a));
    this.pattern = words.length > 1 ? new RegExp(words.map(escapeRegExp).join("\\s+"), "u") : undefined;
  }

  static make(query: string): SearchPhrase | undefined {
    const words = foldQuery(query).split(/\s+/u).filter(Boolean);
    return words.length === 0 ? undefined : new SearchPhrase(words);
  }

  /** The matched UTF-16 range in `candidate`. */
  range(candidate: string): [number, number] | undefined {
    const folded = fold(candidate);
    const found = folded.text.indexOf(this.text);
    if (found !== -1) return unfoldRange(folded, found, found + this.text.length);
    if (this.pattern && folded.text.includes(this.longestWord)) {
      const match = this.pattern.exec(folded.text);
      if (match) return unfoldRange(folded, match.index, match.index + match[0].length);
    }
    return undefined;
  }

  matches(candidate: string): boolean {
    return this.range(candidate) !== undefined;
  }
}

export const ThreadSearch = {
  results(query: string, threads: RecentThread[], limit = 60): ThreadSearchResult[] {
    const phrase = SearchPhrase.make(query);
    if (!phrase) return [];
    const titled: [number, ThreadSearchResult][] = [], other: [number, ThreadSearchResult][] = [];
    for (const entry of threads) {
      const thread = entry.thread;
      if (phrase.matches(thread.title)) {
        titled.push([threadRecentAt(thread), { threadID: thread.id, projectID: entry.project.id }]);
        continue;
      }
      let snippet: string | undefined;
      for (let i = thread.messages.length - 1; i >= 0 && snippet === undefined; i--) {
        const message = thread.messages[i];
        if ((message.role !== "assistant" && message.role !== "user") || !message.text) continue;
        const match = phrase.range(message.text);
        if (match) snippet = snippetText(message.text, match);
      }
      if (snippet === undefined && !phrase.matches(entry.project.name)) continue;
      other.push([threadRecentAt(thread), { threadID: thread.id, projectID: entry.project.id, ...(snippet !== undefined ? { snippet } : {}) }]);
    }
    const byRecent = (a: [number, ThreadSearchResult], b: [number, ThreadSearchResult]) => b[0] - a[0];
    return [...titled.sort(byRecent), ...other.sort(byRecent)].slice(0, limit).map(([, result]) => result);
  },
};

/** One line of the message around `match`, whitespace collapsed, with ellipses where cut. */
export function snippetText(text: string, match: [number, number], before = 30, after = 90): string {
  const head = graphemes(text.slice(0, match[0]));
  const tail = graphemes(text.slice(match[1]));
  const cutStart = head.length > before;
  const cutEnd = tail.length > after;
  const body = (head.slice(Math.max(0, head.length - before)).join("") + text.slice(match[0], match[1]) + tail.slice(0, after).join(""))
    .replace(/\s+/g, " ").trim();
  return (cutStart ? "…" : "") + body + (cutEnd ? "…" : "");
}
