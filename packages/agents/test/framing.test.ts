import { describe, expect, it } from "vitest";
import { JSONLineFramer } from "../src";

describe("JSONLineFramer", () => {
  it("applies the limit to complete, fragmented and final frames", () => {
    for (const chunks of [["123456789\n"], ["123456", "789\n"], ["123456789"]]) {
      const framer = new JSONLineFramer(8);
      const emitted: Buffer[] = [];
      expect(() => chunks.forEach((c) => framer.receive(Buffer.from(c), (l) => emitted.push(l)))).toThrow();
      expect(emitted).toEqual([]);
    }
    const framer = new JSONLineFramer(8);
    const emitted: string[] = [];
    for (const byte of Buffer.from("🐙\ncafé")) framer.receive(Buffer.from([byte]), (l) => emitted.push(l.toString("utf8")));
    framer.finish((l) => emitted.push(l.toString("utf8")));
    expect(emitted).toEqual(["🐙", "café"]);
  });
});
