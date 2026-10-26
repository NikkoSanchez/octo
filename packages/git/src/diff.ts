import type { DiffLine } from "@octo/core";

const HUNK = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;

export const UnifiedDiffParser = {
  parse(patch: string): DiffLine[] {
    const rows: DiffLine[] = [];
    let old = 0, now = 0, inHunk = false;
    for (const text of patch.split("\n")) {
      const match = HUNK.exec(text);
      if (match) {
        old = Number(match[1]); now = Number(match[2]);
        rows.push({ id: rows.length, kind: "header", text }); inHunk = true;
      } else if (inHunk && text.length > 0) {
        switch (text[0]) {
          case "+": rows.push({ id: rows.length, kind: "addition", text: text.slice(1), newLine: now }); now++; break;
          case "-": rows.push({ id: rows.length, kind: "deletion", text: text.slice(1), oldLine: old }); old++; break;
          case " ": rows.push({ id: rows.length, kind: "context", text: text.slice(1), oldLine: old, newLine: now }); old++; now++; break;
          case "\\": rows.push({ id: rows.length, kind: "header", text }); break;
          default: inHunk = false;
        }
      }
    }
    return rows;
  },
};

const isHunkHeader = (line: DiffLine) => line.kind === "header" && line.text.startsWith("@@");

/**
 * Rebuilds one displayed hunk as a patch for `git apply --cached`. The patch carries the context that
 * was shown, so Git rejects it if the index has changed since the diff was read.
 */
export const HunkPatch = {
  /** The header line IDs of each `@@` hunk, in display order. */
  hunkIDs(lines: DiffLine[]): number[] {
    return lines.filter(isHunkHeader).map((l) => l.id);
  },

  /** The hunk containing a displayed line: the nearest `@@` header at or before it. */
  hunkIDContaining(lineID: number, lines: DiffLine[]): number | undefined {
    const index = lines.findIndex((l) => l.id === lineID);
    if (index === -1) return undefined;
    for (let i = index; i >= 0; i--) if (isHunkHeader(lines[i])) return lines[i].id;
    return undefined;
  },

  make(path: string, lines: DiffLine[], id: number): string | undefined {
    const start = lines.findIndex((l) => l.id === id && isHunkHeader(l));
    if (!path || start === -1) return undefined;
    const body = [lines[start].text];
    let changes = 0;
    for (const line of lines.slice(start + 1)) {
      if (isHunkHeader(line)) break;
      switch (line.kind) {
        // Git's "\ No newline at end of file" note belongs to the preceding line.
        case "header": body.push(line.text); break;
        case "context": body.push(" " + line.text); break;
        case "addition": body.push("+" + line.text); changes++; break;
        case "deletion": body.push("-" + line.text); changes++; break;
      }
    }
    if (changes === 0) return undefined;
    const old = HunkPatch.quoted("a/" + path), now = HunkPatch.quoted("b/" + path);
    return `diff --git ${old} ${now}\n--- ${old}\n+++ ${now}\n` + body.join("\n") + "\n";
  },

  /** Git's C-style quoting, for names with quotes, backslashes or control characters. */
  quoted(name: string): string {
    if (![...name].some((c) => c === "\"" || c === "\\" || c.charCodeAt(0) < 0x20 || c.charCodeAt(0) === 0x7f)) return name;
    // Escaping works on UTF-8 bytes; multibyte characters pass through unchanged.
    const bytes: number[] = [];
    for (const byte of Buffer.from(name, "utf8")) {
      if (byte === 0x22) bytes.push(...Buffer.from("\\\""));
      else if (byte === 0x5c) bytes.push(...Buffer.from("\\\\"));
      else if (byte === 0x09) bytes.push(...Buffer.from("\\t"));
      else if (byte === 0x0a) bytes.push(...Buffer.from("\\n"));
      else if (byte === 0x0d) bytes.push(...Buffer.from("\\r"));
      else if (byte < 0x20 || byte === 0x7f) bytes.push(...Buffer.from("\\" + byte.toString(8).padStart(3, "0")));
      else bytes.push(byte);
    }
    return "\"" + Buffer.from(bytes).toString("utf8") + "\"";
  },
};
