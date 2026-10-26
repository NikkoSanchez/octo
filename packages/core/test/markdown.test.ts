import { describe, expect, it } from "vitest";
import {
  decodeMessage, encodeMessage, makeMessage, MarkdownDocument, MarkdownInline, markdownFileLink, chatTurns, durationLabel,
  turnDetails, turnResponses, turnWorkLabel,
} from "../src";

describe("MarkdownDocument", () => {
  it("parses blocks and inline formatting", () => {
    const doc = new MarkdownDocument("# Heading\n\nText **bold** and *italic* with `code` and [link](https://example.com).\n- First\n  continuation\n  - Nested\n12. Ordered\n> Quoted\n> second line\n");
    expect(doc.blocks[0].kind).toEqual({ type: "heading", level: 1, text: "Heading" });
    expect(doc.blocks[3].kind).toEqual({ type: "listItem", marker: "-", depth: 0, text: "First\ncontinuation" });
    expect(doc.blocks[4].kind).toEqual({ type: "listItem", marker: "-", depth: 1, text: "Nested" });
    expect(doc.blocks[5].kind).toEqual({ type: "listItem", marker: "12.", depth: 0, text: "Ordered" });
    expect(doc.blocks[6].kind).toEqual({ type: "quote", text: "Quoted\nsecond line" });
    const inline = MarkdownInline.parse("**bold** *italic* `code` [link](https://example.com)");
    expect(inline.map((r) => r.text).join("")).toBe("bold italic code link");
    expect(inline.some((r) => r.strong)).toBe(true);
    expect(inline.some((r) => r.emphasis)).toBe(true);
    expect(inline.some((r) => r.code)).toBe(true);
    expect(inline.some((r) => r.link === "https://example.com")).toBe(true);
  });

  it("keeps literal code and exact line endings in fences", () => {
    const source = "````swift\r\nlet x = \"**literal**\"\r\n```\r\n~~~~\r\n````\r\nAfter";
    const doc = new MarkdownDocument(source);
    expect(doc.blocks[0].kind).toEqual({ type: "code", language: "swift", text: "let x = \"**literal**\"\r\n```\r\n~~~~\r\n" });
    expect(doc.blocks[1].kind).toEqual({ type: "paragraph", text: "After" });
    expect(doc.blocks.map((b) => b.source).join("")).toBe(source);
    expect(new MarkdownDocument("~~~text\n# literal\n~~~").blocks[0].kind).toEqual({ type: "code", language: "text", text: "# literal\n" });
    expect(new MarkdownDocument("```swift\nlet x = 1").blocks[0].kind).toEqual({ type: "code", language: "swift", text: "let x = 1" });
    expect(new MarkdownDocument("```swift").blocks[0].kind).toEqual({ type: "code", language: "swift", text: "" });
  });

  it("parses tables, alignment, escapes and malformed rows", () => {
    const doc = new MarkdownDocument("| Name | Value |\n| :--- | ---: |\n| a\\|b | `x|y` |\n| incomplete\nTail");
    expect(doc.blocks[0].kind).toEqual({ type: "table", headers: ["Name", "Value"], alignments: ["leading", "trailing"], rows: [["a\\|b", "`x|y`"]] });
    expect(doc.blocks[1].kind).toEqual({ type: "paragraph", text: "| incomplete\nTail" });
    expect(new MarkdownDocument("A | B\n:---: | ---\nx | y").blocks[0].kind)
      .toEqual({ type: "table", headers: ["A", "B"], alignments: ["center", "leading"], rows: [["x", "y"]] });
    expect(new MarkdownDocument("A | B\n--- | --").blocks[0].kind).toEqual({ type: "paragraph", text: "A | B\n--- | --" });
    expect(new MarkdownDocument("| A | B |\n| --- | --- |\n| one | two | extra |").blocks.length).toBe(2);
  });

  it("retains source and stable block IDs for every streaming prefix", () => {
    const source = "# Héllo 👩🏽‍💻\n\n**strong** [link](https://example.com)\n\n| A | B |\n| --- | ---: |\n| a | b |\n\n```swift\nlet x = \"💜\"\n```\n> quote\n- item\n";
    for (let end = 0; end <= source.length; end++) {
      const prefix = source.slice(0, end);
      const doc = new MarkdownDocument(prefix);
      expect(doc.source).toBe(prefix);
      expect(doc.blocks.map((b) => b.source).join("")).toBe(prefix);
      expect(new Set(doc.blocks.map((b) => b.id)).size).toBe(doc.blocks.length);
    }
    expect(new MarkdownDocument("# One\n\nTail").blocks.map((b) => b.id)).toEqual(new MarkdownDocument("# One\n\nTail grows").blocks.map((b) => b.id));
  });

  it("keeps incomplete and unsupported inline syntax visible", () => {
    for (const text of ["**unfinished", "*unfinished", "`unfinished", "[label](https://exam", "[label", "![image](x)", "<b>literal</b>", "\\*literal", "`a*b`", "``a`b``"]) {
      const result = MarkdownInline.plainText(text);
      if (text === "\\*literal") expect(result).toBe("*literal");
      else if (text === "`a*b`") expect(result).toBe("a*b");
      else if (text === "``a`b``") expect(result).toBe("a`b");
      else expect(result).toBe(text);
    }
    expect(MarkdownInline.plainText("one\ntwo")).toBe("one\ntwo");
    expect(MarkdownInline.plainText("**bold** with snake_case")).toBe("bold with snake_case");
  });

  it("keeps the original response through an archive round trip", () => {
    const source = "# Title\r\n\n```swift\nlet x = 1\n```\n**ending";
    const message = makeMessage("assistant", source);
    void new MarkdownDocument(message.text);
    expect(decodeMessage(JSON.parse(JSON.stringify(encodeMessage(message)))).text).toBe(source);
  });
});

describe("Transcript metadata", () => {
  it("preserves local link paths and resolves line references", () => {
    const root = "/tmp/project";
    for (const target of ["/tmp/project/Sources/a.swift:128", "file:///tmp/project/Sources/a.swift#L128", "Sources/a.swift#L128-L130", "Sources/a.swift:128:4"]) {
      expect(markdownFileLink(target, root)).toEqual({ path: "Sources/a.swift", line: 128 });
    }
    expect(markdownFileLink("README.md:12", root)).toEqual({ path: "README.md", line: 12 });
    expect(markdownFileLink("Sources/caf%C3%A9%20%2520.swift", root)?.path).toBe("Sources/café %20.swift");
    for (const target of ["../outside.swift", "/tmp/project-other/file", "file://server/tmp/project/a", "https://example.com/a", "javascript:alert(1)", "Sources/a.swift#invalid"]) {
      expect(markdownFileLink(target, root), target).toBeUndefined();
    }
  });

  it("round-trips timing, decodes legacy messages and groups turns", () => {
    const user = makeMessage("user", "Question", { work: { startedAt: 1_000_000, elapsed: 62, outcome: "completed" } });
    const encoded = JSON.parse(JSON.stringify(encodeMessage(user)));
    expect(decodeMessage(encoded)).toEqual(user);
    expect(turnWorkLabel(user.work!)).toBe("Worked for 1m 2s");
    delete encoded.work; delete encoded.completedAt;
    expect(decodeMessage(encoded).work).toBeUndefined();
    const turns = chatTurns([user, makeMessage("reasoning", "Thinking"), makeMessage("assistant", "Answer"), makeMessage("user", "Next")]);
    expect(turns.length).toBe(2);
    expect(turnDetails(turns[0]).length).toBe(1);
    expect(turnResponses(turns[0]).map((m) => m.text)).toEqual(["Answer"]);
    expect(durationLabel(3602)).toBe("1h 0m");
    expect(durationLabel(-2)).toBe("0s");
    expect(turnWorkLabel({ startedAt: Date.now() })).toBe("Interrupted");
  });
});
