import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ClaudeCLI, ClaudeHarness, CodexHarness, authStatusTitle, codexCommandInput, decodeClaudeCommands, decodeCodexCommands } from "../src";
import { fixture, removeRoot, temporaryRoot, untilEnd, within } from "./helpers";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("Agent commands", () => {
  it("lists Codex skills and sends explicit skill input without changing permissions", async () => {
    const directory = temporaryRoot(); roots.push(directory);
    const commands = await CodexHarness.commands(directory, fixture("codex-skills.py"));
    expect(commands.map((c) => c.name)).toEqual(["fixture-review"]);
    const harness = new CodexHarness(fixture("codex-skills.py"));
    try {
      const end = untilEnd(harness);
      await harness.send("/fixture-review explain", undefined, directory, {}, []);
      expect((await within(end, 5000)).type).toBe("finished");
    } finally { harness.shutdown(); }
  });

  it("rejects the wrong checkout and disabled skills, and preserves arguments", () => {
    const skills = [{ name: "review", enabled: true, path: "/tmp/fixture/SKILL.md" },
      { name: "hidden", enabled: false, path: "/tmp/hidden/SKILL.md" }, { name: "bad", enabled: true, path: "relative/SKILL.md" }];
    const response = { data: [{ cwd: "/tmp", skills }] };
    const commands = decodeCodexCommands(response, "/tmp");
    expect(commands.map((c) => c.name)).toEqual(["review"]);
    expect(() => decodeCodexCommands(response, "/different")).toThrow();
    const input = codexCommandInput("/review explain\n\nCaptured context", commands);
    expect(input[0].text).toBe("$review explain\n\nCaptured context");
    expect(input[1].type).toBe("skill");
    expect(input[1].path).toBe("/tmp/fixture/SKILL.md");
    const midway = codexCommandInput("hello /review then /review again /tmp/review", commands);
    expect(midway[0].text).toBe("hello $review then $review again /tmp/review");
    expect(midway.length).toBe(2); expect(midway[1].name).toBe("review");
    expect(codexCommandInput("src/review", commands).length).toBe(1);
    expect(codexCommandInput("/unknown", commands)[0].text).toBe("/unknown");
  });

  it("steers with the captured turn and does not override permissions", async () => {
    const directory = temporaryRoot(); roots.push(directory);
    const harness = new CodexHarness(fixture("codex-skills.py"));
    try {
      harness.onEvent = () => {};
      await harness.send("/fixture-review hold", undefined, directory, {}, []);
      await harness.steer("/fixture-review explain", []);
    } finally { harness.shutdown(); }
  });

  it("takes the Claude catalog from initialize without sending input", async () => {
    const root = temporaryRoot(); roots.push(root);
    writeFileSync(join(root, ".claude-fixture-permissions.json"), '{"trace":true}');
    const commands = await ClaudeHarness.commands(root, fixture("claude-stream.py"));
    expect(commands).toEqual([{ name: "fixture-review", description: "Review fixture files", argumentHint: "[path]" }]);
    const trace = readFileSync(join(root, ".claude-fixture-trace.jsonl"), "utf8");
    expect(trace.includes('"type": "user"')).toBe(false);
    expect(trace.includes("manual")).toBe(true);
  });

  it("does not insert malformed or duplicate commands", () => {
    const commands = decodeClaudeCommands({ commands: [
      { name: "plugin:review", description: "Review" }, { name: "plugin:review" }, { name: "" }, { name: "bad\nname" }, { name: "/login" }, { name: "name with spaces" }] });
    expect(commands.map((c) => c.name)).toEqual(["plugin:review"]);
    expect(() => decodeClaudeCommands({})).toThrow();
    expect(decodeClaudeCommands({ commands: [] })).toEqual([]);
  });

  it("requires an explicit boolean auth status and keeps no account metadata", () => {
    const status = ClaudeCLI.decodeAuthStatus('{"loggedIn":false,"authMethod":"none","email":"private@example.test"}');
    expect(authStatusTitle(status)).toBe("Signed out");
    expect(status).toEqual({ loggedIn: false, method: "none" });
    expect(authStatusTitle(ClaudeCLI.decodeAuthStatus('{"loggedIn":true,"authMethod":"claude.ai"}'))).toBe("Signed in · claude.ai");
    expect(() => ClaudeCLI.decodeAuthStatus('{"error":"Keychain unavailable"}')).toThrow();
    expect(ClaudeCLI.loginArguments).toEqual(["auth", "login"]);
  });
});
