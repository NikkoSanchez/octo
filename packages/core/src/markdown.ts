/**
 * A deliberately small, lossless block parser. Raw source is never replaced by presentation text,
 * including while a fence or table is still arriving.
 */
export type MarkdownAlignment = "leading" | "center" | "trailing";

export type MarkdownBlockKind =
  | { type: "paragraph"; text: string }
  | { type: "heading"; level: number; text: string }
  | { type: "listItem"; marker: string; depth: number; text: string }
  | { type: "quote"; text: string }
  | { type: "code"; language: string; text: string }
  | { type: "table"; headers: string[]; alignments: MarkdownAlignment[]; rows: string[][] }
  | { type: "spacing" };

export interface MarkdownBlock {
  /** Starting line, stable as a streaming response grows. */
  id: number;
  source: string;
  kind: MarkdownBlockKind;
}

const HEADING = /^ {0,3}(#{1,6})[\t ]+(.+)$/;
const LIST = /^( *)([-+*]|[0-9]{1,9}[.)])[\t ]+(.+)$/;

interface Fence { marker: string; count: number; info: string }

const isBlankLine = (line: string) => line.trim().length === 0;
const leadingSpaces = (line: string) => line.length - line.replace(/^ +/, "").length;

function fence(line: string): Fence | undefined {
  const indent = leadingSpaces(line);
  if (indent > 3) return undefined;
  const body = line.slice(indent);
  const marker = body[0];
  if (marker !== "`" && marker !== "~") return undefined;
  let count = 0;
  while (body[count] === marker) count++;
  const info = body.slice(count).trim();
  if (count < 3 || (marker === "`" && info.includes("`"))) return undefined;
  return { marker, count, info };
}

function closes(line: string, open: Fence): boolean {
  const closing = fence(line);
  return closing !== undefined && closing.marker === open.marker && closing.count >= open.count && closing.info === "";
}

function quoteText(line: string): string | undefined {
  const indent = leadingSpaces(line);
  if (indent > 3) return undefined;
  let body = line.slice(indent);
  if (body[0] !== ">") return undefined;
  body = body.slice(1);
  if (body[0] === " ") body = body.slice(1);
  return body;
}

function startsBlock(line: string): boolean {
  return fence(line) !== undefined || HEADING.test(line) || LIST.test(line) || quoteText(line) !== undefined;
}

/** Split only unescaped pipes outside matched code spans. */
function cells(line: string): string[] | undefined {
  const chars = Array.from(line.trim());
  const result: string[] = [];
  let cell = "", i = 0, ticks = 0, pipes = 0;
  while (i < chars.length) {
    const c = chars[i];
    if (c === "\\" && i + 1 < chars.length) { cell += c + chars[i + 1]; i += 2; continue; }
    if (c === "`") {
      let end = i;
      while (end < chars.length && chars[end] === "`") end++;
      const count = end - i;
      if (ticks === count) ticks = 0;
      else if (ticks === 0) ticks = count;
      cell += "`".repeat(count); i = end; continue;
    }
    if (c === "|" && ticks === 0) { result.push(cell); cell = ""; pipes++; }
    else cell += c;
    i++;
  }
  if (pipes === 0) return undefined;
  result.push(cell);
  if (chars[0] === "|") result.shift();
  if (chars[chars.length - 1] === "|" && result[result.length - 1] === "") result.pop();
  return result.length === 0 ? undefined : result.map((c) => c.trim());
}

function tableAlignment(line: string): MarkdownAlignment[] | undefined {
  const row = cells(line);
  if (!row) return undefined;
  const result: MarkdownAlignment[] = [];
  for (const cell of row) {
    const dashes = cell.replace(/^:+|:+$/g, "");
    if (dashes.length < 3 || !/^-+$/.test(dashes)) return undefined;
    result.push(cell.endsWith(":") ? (cell.startsWith(":") ? "center" : "trailing") : "leading");
  }
  return result;
}

export class MarkdownDocument {
  readonly source: string;
  readonly blocks: MarkdownBlock[];

  constructor(source: string) {
    this.source = source;
    let lines = source.split("\n");
    if (lines[lines.length - 1] === "") lines.pop();
    const raw = lines.map((line, index) => line + (index < lines.length - 1 || source.endsWith("\n") ? "\n" : ""));
    lines = lines.map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line));
    const result: MarkdownBlock[] = [];
    let i = 0;
    while (i < lines.length) {
      const start = i;
      let kind: MarkdownBlockKind;
      const open = fence(lines[i]);
      let match: RegExpExecArray | null;
      if (isBlankLine(lines[i])) {
        i++;
        kind = { type: "spacing" };
      } else if (open) {
        i++;
        const contentStart = i;
        while (i < lines.length && !closes(lines[i], open)) i++;
        const code = raw.slice(contentStart, i).join("");
        if (i < lines.length) i++;
        kind = { type: "code", language: open.info, text: code };
      } else if ((match = HEADING.exec(lines[i]))) {
        kind = { type: "heading", level: match[1].length, text: match[2] };
        i++;
      } else if ((match = LIST.exec(lines[i]))) {
        let text = match[3];
        const indent = match[1].length;
        i++;
        // Indented continuations belong to this item; nested markers get their own row.
        // Preserve unsupported constructs as visible text.
        while (i < lines.length && !isBlankLine(lines[i]) && leadingSpaces(lines[i]) > indent && !startsBlock(lines[i])) {
          text += "\n" + lines[i].trim();
          i++;
        }
        kind = { type: "listItem", marker: match[2], depth: Math.floor(indent / 2), text };
      } else if (quoteText(lines[i]) !== undefined) {
        const text: string[] = [];
        let quoted: string | undefined;
        while (i < lines.length && (quoted = quoteText(lines[i])) !== undefined) { text.push(quoted); i++; }
        kind = { type: "quote", text: text.join("\n") };
      } else if (i + 1 < lines.length && tableHead(lines[i], lines[i + 1])) {
        const headers = cells(lines[i])!;
        const alignments = tableAlignment(lines[i + 1])!;
        i += 2;
        const rows: string[][] = [];
        // A partial/malformed row stays a paragraph instead of losing cells.
        let row: string[] | undefined;
        while (i < lines.length && (row = cells(lines[i])) !== undefined && row.length === headers.length && !startsBlock(lines[i])) {
          rows.push(row); i++;
        }
        kind = { type: "table", headers, alignments, rows };
      } else {
        i++;
        while (i < lines.length && !isBlankLine(lines[i]) && !startsBlock(lines[i])) {
          if (i + 1 < lines.length && tableHead(lines[i], lines[i + 1])) break;
          i++;
        }
        kind = { type: "paragraph", text: lines.slice(start, i).join("\n") };
      }
      result.push({ id: start, source: raw.slice(start, i).join(""), kind });
    }
    this.blocks = result;
  }
}

function tableHead(header: string, separator: string): boolean {
  const headers = cells(header);
  const alignment = tableAlignment(separator);
  return headers !== undefined && alignment !== undefined && headers.length === alignment.length;
}

// MARK: Inline

export interface InlineRun {
  text: string;
  strong?: boolean;
  emphasis?: boolean;
  code?: boolean;
  strikethrough?: boolean;
  link?: string;
}

type InlineNode =
  | { type: "text"; text: string }
  | { type: "code"; text: string }
  | { type: "emphasis" | "strong" | "strike"; children: InlineNode[] }
  | { type: "link"; href: string; children: InlineNode[] };

interface Delimiter {
  char: string;
  count: number;
  original: number;
  canOpen: boolean;
  canClose: boolean;
  /** Index of the text node holding the run. */
  node: number;
}

const ASCII_PUNCTUATION = /[!-/:-@[-`{-~]/;
const UNICODE_PUNCTUATION = /[\p{P}\p{S}]/u;
const WHITESPACE = /\s/u;

function isPunctuation(char: string | undefined): boolean {
  return char !== undefined && UNICODE_PUNCTUATION.test(char);
}
function isWhitespace(char: string | undefined): boolean {
  return char === undefined || WHITESPACE.test(char);
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

export const MarkdownInline = {
  /**
   * Inline Markdown as styled runs. Incomplete syntax stays literal until it closes, so a link
   * destination still arriving is never concealed. Images and HTML stay literal too.
   */
  parse(source: string): InlineRun[] {
    if (!isComplete(source) || source.includes("![") || source.includes("<")) return source ? [{ text: source }] : [];
    const nodes = parseInline(source);
    const runs: InlineRun[] = [];
    flatten(nodes, {}, runs);
    return mergeRuns(runs);
  },
  /** The visible characters of the parsed text, like `String(attributed.characters)`. */
  plainText(source: string): string {
    return MarkdownInline.parse(source).map((run) => run.text).join("");
  },
};

function isComplete(source: string): boolean {
  const chars = Array.from(source);
  let i = 0, brackets = 0, parentheses = 0, ticks = 0;
  while (i < chars.length) {
    const c = chars[i];
    if (c === "\\") { i += 2; continue; }
    if (c === "`") {
      let end = i;
      while (end < chars.length && chars[end] === "`") end++;
      if (ticks === end - i) ticks = 0; else if (ticks === 0) ticks = end - i;
      i = end; continue;
    }
    if (ticks === 0) {
      if (c === "[") brackets++;
      if (c === "]") brackets = Math.max(0, brackets - 1);
      if (c === "(" && (parentheses > 0 || (i > 0 && chars[i - 1] === "]"))) parentheses++;
      if (c === ")" && parentheses > 0) parentheses--;
    }
    i++;
  }
  // Unmatched emphasis delimiters already stay literal, including underscores inside
  // identifiers; only guard constructs that hide tails.
  return ticks === 0 && brackets === 0 && parentheses === 0;
}

function parseInline(source: string): InlineNode[] {
  const nodes: InlineNode[] = [];
  const delimiters: Delimiter[] = [];
  const brackets: { node: number; delimiterBottom: number; active: boolean }[] = [];
  let text = "";
  const flushText = () => { if (text) { nodes.push({ type: "text", text }); text = ""; } };
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === "\\") {
      const next = source[i + 1];
      if (next !== undefined && ASCII_PUNCTUATION.test(next)) { text += next; i += 2; continue; }
      if (next === "\n") { text += "\n"; i += 2; continue; }
      text += c; i++; continue;
    }
    if (c === "&") {
      const entity = /^&(?:#([0-9]{1,7})|#[xX]([0-9a-fA-F]{1,6})|([A-Za-z]+));/.exec(source.slice(i));
      if (entity) {
        const value = entity[1] ? String.fromCodePoint(Number(entity[1]) || 0xfffd)
          : entity[2] ? String.fromCodePoint(parseInt(entity[2], 16) || 0xfffd)
          : ENTITIES[entity[3].toLowerCase()];
        if (value !== undefined) { text += value; i += entity[0].length; continue; }
      }
      text += c; i++; continue;
    }
    if (c === "`") {
      let end = i;
      while (source[end] === "`") end++;
      const run = end - i;
      let search = end, close = -1;
      while (search < source.length) {
        const found = source.indexOf("`".repeat(run), search);
        if (found === -1) break;
        let after = found + run;
        if (source[after] === "`") { while (source[after] === "`") after++; search = after; continue; }
        if (found > 0 && source[found - 1] === "`") { search = found + 1; continue; }
        close = found; break;
      }
      if (close === -1) { text += "`".repeat(run); i = end; continue; }
      let content = source.slice(end, close).replace(/\r\n|\r|\n/g, " ");
      if (content.length >= 2 && content.startsWith(" ") && content.endsWith(" ") && content.trim() !== "") content = content.slice(1, -1);
      flushText();
      nodes.push({ type: "code", text: content });
      i = close + run; continue;
    }
    if (c === "*" || c === "_" || c === "~") {
      let end = i;
      while (source[end] === c) end++;
      const count = end - i;
      if (c === "~" && count !== 2) { text += source.slice(i, end); i = end; continue; }
      const before = i > 0 ? previousChar(source, i) : undefined;
      const after = end < source.length ? nextChar(source, end) : undefined;
      const leftFlanking = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before));
      const rightFlanking = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after));
      let canOpen = leftFlanking, canClose = rightFlanking;
      if (c === "_") {
        canOpen = leftFlanking && (!rightFlanking || isPunctuation(before));
        canClose = rightFlanking && (!leftFlanking || isPunctuation(after));
      }
      flushText();
      nodes.push({ type: "text", text: source.slice(i, end) });
      if (canOpen || canClose) delimiters.push({ char: c, count, original: count, canOpen, canClose, node: nodes.length - 1 });
      i = end; continue;
    }
    if (c === "[") {
      flushText();
      nodes.push({ type: "text", text: "[" });
      brackets.push({ node: nodes.length - 1, delimiterBottom: delimiters.length, active: true });
      i++; continue;
    }
    if (c === "]") {
      const opener = brackets.pop();
      const destination = opener?.active ? linkDestination(source, i + 1) : undefined;
      if (!opener || !destination) {
        text += "]"; i++; continue;
      }
      flushText();
      const inner = nodes.splice(opener.node + 1);
      nodes.pop(); // the "[" text
      const innerDelimiters = delimiters.splice(opener.delimiterBottom)
        .map((d) => ({ ...d, node: d.node - opener.node - 1 }));
      const children = processEmphasis(inner, innerDelimiters);
      nodes.push({ type: "link", href: destination.href, children });
      // Links may not contain other links.
      for (const bracket of brackets) bracket.active = false;
      i = destination.end; continue;
    }
    text += c;
    i++;
  }
  flushText();
  return processEmphasis(nodes, delimiters);
}

function previousChar(source: string, index: number): string {
  const code = source.charCodeAt(index - 1);
  if (code >= 0xdc00 && code <= 0xdfff && index >= 2) return source.slice(index - 2, index);
  return source[index - 1];
}
function nextChar(source: string, index: number): string {
  return String.fromCodePoint(source.codePointAt(index)!);
}

function linkDestination(source: string, start: number): { href: string; end: number } | undefined {
  if (source[start] !== "(") return undefined;
  let i = start + 1;
  while (source[i] === " " || source[i] === "\t" || source[i] === "\n") i++;
  let depth = 0, href = "";
  while (i < source.length) {
    const c = source[i];
    if (c === "\\" && i + 1 < source.length && ASCII_PUNCTUATION.test(source[i + 1])) { href += source[i + 1]; i += 2; continue; }
    if (/\s/.test(c)) break;
    if (c === "(") depth++;
    if (c === ")") { if (depth === 0) break; depth--; }
    href += c; i++;
  }
  while (source[i] === " " || source[i] === "\t" || source[i] === "\n") i++;
  const quote = source[i];
  if (quote === "\"" || quote === "'" || quote === "(") {
    const closing = quote === "(" ? ")" : quote;
    const close = source.indexOf(closing, i + 1);
    if (close === -1) return undefined;
    i = close + 1;
    while (source[i] === " " || source[i] === "\t" || source[i] === "\n") i++;
  }
  if (source[i] !== ")") return undefined;
  return { href, end: i + 1 };
}

/** CommonMark's "process emphasis" over one node list. Consumed delimiter text becomes styling. */
function processEmphasis(nodes: InlineNode[], delimiters: Delimiter[]): InlineNode[] {
  // Each delimiter run is a text node; wrapping replaces ranges, so work on index-linked records.
  type Entry = { node: InlineNode; delimiter?: Delimiter };
  let entries: Entry[] = nodes.map((node) => ({ node }));
  for (const d of delimiters) entries[d.node].delimiter = d;
  const openersBottom = new Map<string, number>();
  let closerIndex = 0;
  const delimiterText = (entry: Entry) => (entry.node as { text: string }).text;
  while (closerIndex < entries.length) {
    const closer = entries[closerIndex].delimiter;
    if (!closer || !closer.canClose || closer.count === 0) { closerIndex++; continue; }
    const key = `${closer.char}${closer.canOpen}${closer.original % 3}`;
    const bottom = openersBottom.get(key) ?? -1;
    let openerIndex = closerIndex - 1, found = -1;
    while (openerIndex > bottom) {
      const opener = entries[openerIndex].delimiter;
      if (opener && opener.char === closer.char && opener.canOpen && opener.count > 0) {
        const oddMatch = (opener.canClose || closer.canOpen) && (opener.original + closer.original) % 3 === 0 &&
          !(opener.original % 3 === 0 && closer.original % 3 === 0);
        if (!oddMatch) { found = openerIndex; break; }
      }
      openerIndex--;
    }
    if (found === -1) {
      openersBottom.set(key, closerIndex - 1);
      if (!closer.canOpen) entries[closerIndex].delimiter = undefined;
      closerIndex++;
      continue;
    }
    const opener = entries[found].delimiter!;
    let type: "emphasis" | "strong" | "strike";
    let used: number;
    if (closer.char === "~") { type = "strike"; used = 2; }
    else { used = opener.count >= 2 && closer.count >= 2 ? 2 : 1; type = used === 2 ? "strong" : "emphasis"; }
    opener.count -= used; closer.count -= used;
    const openerText = delimiterText(entries[found]);
    const closerText = delimiterText(entries[closerIndex]);
    entries[found].node = { type: "text", text: openerText.slice(0, openerText.length - used) };
    entries[closerIndex].node = { type: "text", text: closerText.slice(used) };
    const inner = entries.slice(found + 1, closerIndex).map((e) => e.node);
    const wrapped: Entry = { node: { type, children: inner } };
    entries = [...entries.slice(0, found + 1), wrapped, ...entries.slice(closerIndex)];
    // Delimiters between opener and closer are consumed by the wrap.
    closerIndex = found + 2;
    for (const [k, v] of openersBottom) if (v > found) openersBottom.set(k, found);
    if (opener.count === 0) entries[found].delimiter = undefined;
    if (closer.count === 0) { entries[closerIndex].delimiter = undefined; closerIndex++; }
  }
  return entries.map((e) => e.node).filter((node) => node.type !== "text" || node.text !== "");
}

function flatten(nodes: InlineNode[], style: Omit<InlineRun, "text">, out: InlineRun[]): void {
  for (const node of nodes) {
    switch (node.type) {
      case "text": out.push({ ...style, text: node.text }); break;
      case "code": out.push({ ...style, code: true, text: node.text }); break;
      case "emphasis": flatten(node.children, { ...style, emphasis: true }, out); break;
      case "strong": flatten(node.children, { ...style, strong: true }, out); break;
      case "strike": flatten(node.children, { ...style, strikethrough: true }, out); break;
      case "link": flatten(node.children, { ...style, link: node.href }, out); break;
    }
  }
}

function mergeRuns(runs: InlineRun[]): InlineRun[] {
  const merged: InlineRun[] = [];
  for (const run of runs) {
    const last = merged[merged.length - 1];
    if (last && last.strong === run.strong && last.emphasis === run.emphasis && last.code === run.code &&
        last.strikethrough === run.strikethrough && last.link === run.link) last.text += run.text;
    else merged.push({ ...run });
  }
  return merged;
}

// MARK: File links

/**
 * Local Markdown destinations are resolved against the owning thread's checkout. This is
 * navigation only; file reads remain bounded, no-follow reads.
 */
export interface MarkdownFileLink {
  path: string;
  line?: number;
}

const SCHEME = /^([A-Za-z][A-Za-z0-9+.-]*):/;
const BARE_FILE = /^[^/:]+:[1-9][0-9]*(?::[1-9][0-9]*)?$/;

function decodeOnce(value: string): string | undefined {
  try { return decodeURIComponent(value); } catch { return undefined; }
}

function standardize(path: string): string {
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop(); else parts.push(part);
  }
  return "/" + parts.join("/");
}

export function markdownFileLink(href: string, checkout: string): MarkdownFileLink | undefined {
  const scheme = SCHEME.exec(href)?.[1]?.toLowerCase();
  // `README.md:12` parses as a URL with scheme `README.md`.
  const bareFile = scheme !== undefined && scheme.includes(".") && BARE_FILE.test(href);
  if (scheme !== undefined && scheme !== "file" && !bareFile) return undefined;
  let rest = href;
  let fragment: string | undefined;
  if (!bareFile) {
    const hash = rest.indexOf("#");
    if (hash !== -1) { fragment = rest.slice(hash + 1); rest = rest.slice(0, hash); }
    if (rest.includes("?")) return undefined;
    if (scheme === "file") {
      rest = rest.slice("file:".length);
      if (rest.startsWith("//")) {
        const slash = rest.indexOf("/", 2);
        const host = slash === -1 ? rest.slice(2) : rest.slice(2, slash);
        if (host !== "" && host !== "localhost") return undefined;
        rest = slash === -1 ? "" : rest.slice(slash);
      }
    } else if (rest.startsWith("//")) {
      return undefined;
    }
  }
  let path = decodeOnce(rest);
  if (!path) return undefined;
  let line: number | undefined;
  if (fragment !== undefined) {
    const match = /^L?([1-9][0-9]*)(?:C[1-9][0-9]*)?(?:-L?[1-9][0-9]*)?$/.exec(fragment);
    if (!match) return undefined;
    line = Number(match[1]);
  }
  const suffix = /:([1-9][0-9]*)(?::[1-9][0-9]*)?$/.exec(path);
  if (suffix) {
    if (line === undefined) line = Number(suffix[1]);
    path = path.slice(0, suffix.index);
  }
  const root = standardize(checkout);
  const destination = standardize(path.startsWith("/") ? path : `${root}/${path}`);
  const prefix = root === "/" ? "/" : root + "/";
  if (!destination.startsWith(prefix) || destination.length <= prefix.length) return undefined;
  return { path: destination.slice(prefix.length), ...(line !== undefined ? { line } : {}) };
}
