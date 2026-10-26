import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { makeImage } from "@octo/core";
import { CodexHarness } from "../src";
import { deferred, eventually, fixture, removeRoot, temporaryRoot, untilEnd, within } from "./helpers";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });
const steering = fixture("codex-steering.py");

function requests(root: string, method: string): Record<string, unknown>[] {
  return readFileSync(join(root, "fixture-rpc.jsonl"), "utf8").split("\n").filter(Boolean)
    .map((line) => JSON.parse(line)).filter((v) => v.method === method).map((v) => v.params);
}

describe("Codex steering and Computer Use cleanup", () => {
  it("frames steering, refuses rejections and handles the completion race", async () => {
    const root = temporaryRoot(); roots.push(root);
    const harness = new CodexHarness(steering);
    try {
      const question = deferred();
      let interactions = 0;
      const end = untilEnd(harness, (event) => {
        if (event.type === "interaction") { interactions++; question.resolve(); }
        if (event.type === "failed") throw new Error(event.text);
      });
      await harness.send("wait", undefined, root);
      await within(question.promise, 5000);
      await expect(harness.steer("reject")).rejects.toThrow();
      const image = makeImage(Buffer.from("fixture-image").toString("base64"), "fixture");
      await harness.steer("Guidance", [image]);
      expect(interactions).toBe(1);
      await harness.steer("finish before ack");
      expect((await within(end, 5000)).type).toBe("finished");
      const steers = requests(root, "turn/steer");
      expect(steers.length).toBe(3);
      expect(steers[1].expectedTurnId).toBe("turn-1");
      expect((steers[1].input as { url?: string }[]).at(-1)?.url).toBe("data:image/png;base64," + image.pngBase64);
      expect(requests(root, "turn/start").length).toBe(1);
      const cleanups = requests(root, "mcpServer/tool/call");
      expect(cleanups.length).toBe(1);
      expect((cleanups[0].arguments as Record<string, string>).hook_event_name).toBe("Stop");
      await expect(harness.steer("Too late")).rejects.toThrow();
    } finally { harness.shutdown(); }
  });

  it("cleans up on completion, interruption and failure before the next turn", async () => {
    const root = temporaryRoot(); roots.push(root);
    const harness = new CodexHarness(steering);
    try {
      let warnings = 0;
      const prompts = ["complete", "hold", "cleanup error", "no tool"];
      for (const [index, prompt] of prompts.entries()) {
        const end = untilEnd(harness, (event) => { if (event.type === "interactionUnavailable") warnings++; });
        await harness.send(prompt, "fixture", root);
        if (prompt === "hold") await harness.interrupt();
        const result = await within(end, 8000);
        expect(result.type).toBe(prompt === "hold" ? "interrupted" : "finished");
        expect(requests(root, "mcpServer/tool/call").length).toBe(Math.min(index + 1, 3));
      }
      expect(warnings).toBe(1);
      const cleanups = requests(root, "mcpServer/tool/call");
      expect((cleanups[1].arguments as Record<string, string>).hook_event_name).toBe("Interrupt");
      expect((cleanups[2].arguments as Record<string, string>).turn_id).toBe("turn-3");
    } finally { harness.shutdown(); }
  });

  it("cleans only its own Computer Use turn on shutdown", async () => {
    const root = temporaryRoot(); roots.push(root);
    const harness = new CodexHarness(steering);
    const activity = deferred();
    harness.onEvent = (event) => { if (event.type === "toolActivity" && event.tool.state === "running") activity.resolve(); };
    await harness.send("hold", undefined, root);
    await within(activity.promise, 5000);
    harness.shutdown(); harness.shutdown();
    await eventually(() => { try { return requests(root, "mcpServer/tool/call").length === 1; } catch { return false; } });
    expect(requests(root, "mcpServer/tool/call").length).toBe(1);
    expect(requests(root, "turn/interrupt").length).toBe(1);
  });
});
