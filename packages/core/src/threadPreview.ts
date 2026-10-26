import { MarkdownInline } from "./markdown";
import { graphemes } from "./text";
import type { WorkspaceThread } from "./workspace";

/** The one-line summary under a sidebar thread title, after Messages' last-message preview. */
export const ThreadPreview = {
  /** Only the head of a reply is read; previews show one line. */
  readLimit: 600,
  length: 160,

  /** The newest reply, or the user's own last message when nothing has answered it yet. */
  text(thread: WorkspaceThread): string | undefined {
    const message = [...thread.messages].reverse().find((m) => (m.role === "assistant" || m.role === "user") && m.text);
    if (!message) return undefined;
    const text = ThreadPreview.plain(message.text);
    if (!text) return undefined;
    return message.role === "user" ? "You: " + text : text;
  },

  /**
   * Markdown reduced to readable inline text: code blocks, headings, quotes and list markers
   * removed, inline formatting resolved, whitespace collapsed.
   */
  plain(markdown: string): string {
    const lines: string[] = [];
    let fenced = false;
    const head = graphemes(markdown).slice(0, ThreadPreview.readLimit).join("");
    for (const line of head.split("\n")) {
      if (!line) continue;
      const trimmed = line.replace(/^[ \t]+/, "");
      if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) { fenced = !fenced; continue; }
      if (fenced) continue;
      lines.push(stripBlockMarker(trimmed));
    }
    // The transcript's own inline parser drops emphasis markers, code ticks and link targets.
    const text = MarkdownInline.plainText(lines.join(" ")).replace(/\s+/g, " ").trim();
    const characters = graphemes(text);
    if (characters.length <= ThreadPreview.length) return text;
    return characters.slice(0, ThreadPreview.length - 1).join("").trim() + "…";
  },
};

function stripBlockMarker(input: string): string {
  let line = input;
  while (line[0] === "#" || line[0] === ">") line = line.slice(1).replace(/^ +/, "");
  if (line[0] !== undefined && "-*+".includes(line[0]) && line[1] === " ") return line.slice(2);
  const ordered = /^[0-9]+[.)] /.exec(line);
  if (ordered) return line.slice(ordered[0].length);
  return line;
}
