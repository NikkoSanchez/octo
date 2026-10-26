import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

describe("core purity", () => {
  it("keeps the shared entry free of Node, Electron and DOM imports", () => {
    const directory = join(__dirname, "../src");
    for (const name of readdirSync(directory).filter((n) => n.endsWith(".ts"))) {
      const source = readFileSync(join(directory, name), "utf8");
      expect(source, name).not.toMatch(/from\s+["'](node:|electron|react)/);
      expect(source, name).not.toMatch(/\bwindow\.|\bdocument\.(createElement|body|getElement|query|addEventListener)/);
    }
  });
});

describe("renderer-safe entry points", () => {
  it("keeps @octo/agents/model and @octo/git/model free of Node and process code", () => {
    for (const [directory, entry] of [[join(__dirname, "../../agents/src"), "model.ts"], [join(__dirname, "../../git/src"), "model.ts"]] as const) {
      const seen = new Set<string>();
      const visit = (name: string) => {
        if (seen.has(name)) return;
        seen.add(name);
        const source = readFileSync(join(directory, name), "utf8");
        expect(source, name).not.toMatch(/from\s+["'](node:|electron|@octo\/core\/node)/);
        for (const match of source.matchAll(/from\s+["']\.\/([\w]+)["']/g)) visit(`${match[1]}.ts`);
      };
      visit(entry);
    }
  });
});
