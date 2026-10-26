import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CodexExecutable } from "../src";
import { removeRoot, temporaryRoot } from "./helpers";

let root = "";
afterEach(() => removeRoot(root));

describe("CodexExecutable", () => {
  it("prefers the bundled CLI, honors a custom override and never falls back from a missing one", () => {
    root = temporaryRoot();
    const bundle = join(root, "Desktop App/codex");
    mkdirSync(dirname(bundle), { recursive: true });
    const path = join(root, "path-codex");
    for (const file of [bundle, path]) { writeFileSync(file, "#!/bin/sh\nexit 0\n"); chmodSync(file, 0o700); }
    expect(CodexExecutable.resolve(undefined, [bundle], path)).toBe(bundle);
    expect(CodexExecutable.resolve(path, [bundle], path)).toBe(path);
    expect(CodexExecutable.resolve(undefined, ["/missing"], path)).toBe(path);
    expect(CodexExecutable.resolve("/missing", [bundle], path)).toBeUndefined();
    expect(CodexExecutable.executableAt(root)).toBeUndefined();
    expect(CodexExecutable.executableAt("relative/codex")).toBeUndefined();
    chmodSync(bundle, 0o600);
    expect(CodexExecutable.resolve(undefined, [bundle], path)).toBe(path);
  });
});
