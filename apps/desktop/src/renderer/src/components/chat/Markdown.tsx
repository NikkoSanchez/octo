import { createContext, memo, useContext, useMemo, type ReactNode } from "react";
import { Copy } from "lucide-react";
import { MarkdownDocument, MarkdownInline, ThreadFind } from "@octo/core";
import { openMarkdownLink } from "../../lib/workspace";
import { run } from "../../bridge";
import { HoverButton } from "../controls";
import styles from "./chat.module.css";

/** The find query to highlight in a matching message; `current` is the message ⌘G is on. */
export interface FindHighlight { query: string; current: boolean }
export const FindHighlightContext = createContext<FindHighlight | undefined>(undefined);

/** Text with each occurrence of the find query marked, as Safari's find does. */
export function Highlighted({ text }: { text: string }) {
  const highlight = useContext(FindHighlightContext);
  if (!highlight) return text;
  const ranges = ThreadFind.ranges(highlight.query, text);
  if (!ranges.length) return text;
  const parts: ReactNode[] = [];
  let end = 0;
  ranges.forEach(([start, stop], index) => {
    parts.push(text.slice(end, start), <mark key={index} className={highlight.current ? styles.markCurrent : styles.mark}>{text.slice(start, stop)}</mark>);
    end = stop;
  });
  parts.push(text.slice(end));
  return parts;
}

function Inline({ text }: { text: string }) {
  const runs = useMemo(() => MarkdownInline.parse(text), [text]);
  return runs.map((run, index) => {
    let node: ReactNode = <Highlighted text={run.text} />;
    if (run.code) node = <code>{node}</code>;
    if (run.strong) node = <strong>{node}</strong>;
    if (run.emphasis) node = <em>{node}</em>;
    if (run.strikethrough) node = <s>{node}</s>;
    if (run.link) {
      const href = run.link;
      node = <a href={href} title={href} onClick={(event) => { event.preventDefault(); openMarkdownLink(href); }}>{node}</a>;
    }
    return <span key={index}>{node}</span>;
  });
}

const HEADING_SIZES = [22, 19, 17, 15, 14, 14];

/** An agent's reply, parsed once per text, never per keystroke. */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  const document = useMemo(() => new MarkdownDocument(text), [text]);
  return (
    <div className={styles.markdown}>
      {document.blocks.map(({ id, kind }) => {
        switch (kind.type) {
          case "spacing": return null;
          case "paragraph": return <p key={id}><Inline text={kind.text} /></p>;
          case "heading":
            return <div key={id} role="heading" aria-level={kind.level} className={styles.heading} style={{ fontSize: HEADING_SIZES[kind.level - 1] }}><Inline text={kind.text} /></div>;
          case "listItem":
            return (
              <div key={id} className={styles.listItem} style={{ paddingLeft: Math.min(kind.depth, 12) * 16 }}>
                <span className={styles.marker}>{[...kind.marker].length === 1 ? "•" : kind.marker}</span>
                <span><Inline text={kind.text} /></span>
              </div>
            );
          case "quote": return <blockquote key={id}><Inline text={kind.text} /></blockquote>;
          case "code":
            return (
              <div key={id} className={styles.codeBlock}>
                <div className={styles.codeHeader}>
                  <span>{kind.language || "Code"}</span>
                  <HoverButton aria-label="Copy code" onClick={() => run("app", "copyText", kind.text)}><Copy size={12} />Copy</HoverButton>
                </div>
                <pre><code><Highlighted text={kind.text} /></code></pre>
              </div>
            );
          case "table":
            return (
              <div key={id} className={styles.table}>
                <table>
                  <thead><tr>{kind.headers.map((cell, i) => <th key={i} style={{ textAlign: align(kind.alignments[i]) }}><Inline text={cell} /></th>)}</tr></thead>
                  <tbody>{kind.rows.map((row, r) => <tr key={r}>{row.map((cell, i) => <td key={i} style={{ textAlign: align(kind.alignments[i]) }}><Inline text={cell} /></td>)}</tr>)}</tbody>
                </table>
              </div>
            );
        }
      })}
    </div>
  );
});

const align = (alignment: string | undefined) => alignment === "trailing" ? "right" : alignment === "center" ? "center" : "left";
