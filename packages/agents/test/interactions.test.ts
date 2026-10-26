import { afterEach, describe, expect, it } from "vitest";
import {
  AgentToolDetails, booleanValue, CodexHarness, CodexInteraction, interactionValidationError, numberValue, textValue,
  type AgentInteraction, type AgentInteractionResponse,
} from "../src";
import type { ToolActivity as CoreToolActivity } from "@octo/core";
import { deferred, dedent, executable, fixture, removeRoot, sleep, temporaryRoot, untilEnd, within } from "./helpers";
import { existsSync } from "node:fs";
import { join } from "node:path";

type Obj = Record<string, unknown>;
const form = (): Obj => ({
  mode: "form", message: "Allow ChatGPT to use Safari?", serverName: "computer-use", threadId: "thread", turnId: "turn",
  _meta: { app_name: "Safari", persist: ["session", "always"] },
  requestedSchema: { type: "object", properties: { approval: { type: "string", oneOf: [{ const: "once", title: "Allow once" }, { const: "session", title: "This session" }, { const: "always", title: "Always allow Safari" }] } }, required: ["approval"] },
});
const metadataForm = (): Obj => ({
  mode: "form", message: "Allow Computer Use to use Safari?",
  _meta: { codex_approval_kind: "mcp_tool_call", connector_id: "computer-use", tool_name: "get_app_state", tool_params: { app: "com.apple.Safari" },
    tool_params_display: [{ name: "app", value: "Safari" }], persist: ["session", "always"] },
  requestedSchema: { type: "object", properties: {} },
});
const submit = (values: Record<string, ReturnType<typeof textValue>>): AgentInteractionResponse => ({ type: "submit", values });
const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });
const interactionsFixture = fixture("codex-interactions.py");

describe("Codex interactions", () => {
  it("offers exact app choices and requires explicit consent", () => {
    const decoded = CodexInteraction.decode(form(), false);
    expect(decoded.request.target).toBe("Safari");
    expect(decoded.request.fields[0].options.map((o) => o.id)).toEqual(["once", "session", "always"]);
    expect(interactionValidationError(decoded.request, {})).toBeDefined();
    for (const choice of ["once", "session", "always"]) {
      const result = decoded.response(submit({ approval: textValue(choice) }));
      expect(result.action).toBe("accept");
      expect(result.content).toEqual({ approval: choice });
      expect((result._meta as Obj | undefined)?.persist).toBe(choice === "once" ? undefined : choice);
    }
    expect(() => decoded.response(submit({ approval: textValue("permanent") }))).toThrow();
    expect(() => decoded.response({ type: "submit", values: { approval: booleanValue(true) } })).toThrow();
    expect(() => decoded.response({ type: "submit", values: { approval: textValue("once"), extra: booleanValue(true) } })).toThrow();
    expect(decoded.response({ type: "decline" }).action).toBe("decline");
    expect(decoded.response({ type: "cancel" }).action).toBe("cancel");
    expect(decoded.response({ type: "cancel" }).content).toBeNull();
  });

  it("returns exact metadata and empty content for Computer Use scopes", () => {
    const decoded = CodexInteraction.decode(metadataForm(), false);
    expect(decoded.request.target).toBe("Safari (com.apple.Safari)");
    const field = decoded.request.fields[0];
    expect(field.options.map((o) => o.id)).toEqual(["once", "session", "always"]);
    expect(() => decoded.response({ type: "submit", values: {} })).toThrow();
    for (const scope of ["once", "session", "always"]) {
      const result = decoded.response(submit({ [field.id]: textValue(scope) }));
      expect(result.action).toBe("accept");
      expect(result.content).toEqual({});
      expect((result._meta as Obj | undefined)?.persist).toBe(scope === "once" ? undefined : scope);
    }
    for (const response of [{ type: "decline" }, { type: "cancel" }] as AgentInteractionResponse[]) {
      const result = decoded.response(response);
      expect(result.content).toBeNull();
      expect(result._meta).toBeUndefined();
    }
  });

  it("restricts metadata scopes and supports a session-only provider", () => {
    let p = metadataForm();
    const meta = { ...(p._meta as Obj), persist: ["session"] };
    p._meta = meta;
    const decoded = CodexInteraction.decode(p, false);
    const field = decoded.request.fields[0];
    expect(field.options.map((o) => o.id)).toEqual(["once", "session"]);
    expect(() => decoded.response(submit({ [field.id]: textValue("always") }))).toThrow();
    for (const [key, value] of [["persist", ["session", "unknown"]], ["persist", "session"], ["persist", ["session", "session"]],
      ["connector_id", "another-tool"], ["codex_approval_kind", "unknown"], ["tool_params", { app: "" }], ["tool_name", ""]] as [string, unknown][]) {
      p._meta = { ...meta, [key]: value };
      expect(CodexInteraction.decode(p, false).request.fields).toEqual([]);
    }
    p = metadataForm();
    p.requestedSchema = { type: "object", properties: { approval: { type: "string", enum: ["once"] } }, required: ["approval"] };
    const constrained = CodexInteraction.decode(p, false);
    expect(constrained.request.fields.length).toBe(1);
    expect(constrained.request.fields[0].options.map((o) => o.id)).toEqual(["once"]);
    expect(constrained.response(submit({ approval: textValue("once") }))._meta).toBeUndefined();
  });

  it("cannot broaden a schema with metadata, and defaults never consent", () => {
    const p = form();
    p.requestedSchema = { type: "object", properties: { approval: { type: "string", enum: ["once"], default: "once" } }, required: ["approval"] };
    let decoded = CodexInteraction.decode(p, false);
    expect(decoded.request.fields[0].options.map((o) => o.id)).toEqual(["once"]);
    expect(() => decoded.response({ type: "submit", values: {} })).toThrow();
    expect(decoded.response(submit({ approval: textValue("once") }))._meta).toBeUndefined();
    p.requestedSchema = { type: "object", properties: { always: { type: "boolean", title: "Always allow Safari", default: true } }, required: ["always"] };
    decoded = CodexInteraction.decode(p, false);
    expect(() => decoded.response({ type: "submit", values: {} })).toThrow();
    expect((decoded.response({ type: "submit", values: { always: booleanValue(true) } })._meta as Obj).persist).toBe("always");
    expect(decoded.response({ type: "submit", values: { always: booleanValue(false) } })._meta).toBeUndefined();
    p.requestedSchema = { type: "object", properties: { approval: { type: "string", enum: ["allow"], title: null, enumNames: null } }, required: ["approval"] };
    decoded = CodexInteraction.decode(p, false);
    expect(decoded.response(submit({ approval: textValue("allow") }))._meta).toBeUndefined();
  });

  it("rejects malformed, unsupported and ambiguous forms", () => {
    for (const field of [
      { type: "string", pattern: ".*" }, { type: "object" }, { type: "array" }, { type: "string", format: "email" },
      { type: "string", enum: ["a", "a"] }, { type: "string", enum: [] }, { type: "string", enum: ["a"], enumNames: ["a", "b"] },
      { type: "string", minLength: true }, { type: "string", minLength: 5, maxLength: 2 }, { type: "number", maximum: "ten" },
      { type: "boolean", enum: ["yes"] },
    ]) {
      const p = form(); p.requestedSchema = { type: "object", properties: { field } };
      expect(() => CodexInteraction.decode(p, false), JSON.stringify(field)).toThrow();
    }
    for (const mode of ["url", "openai/userVerification", "unknown"]) {
      const p = form(); p.mode = mode;
      expect(() => CodexInteraction.decode(p, false)).toThrow();
    }
    const p = form(); p.requestedSchema = { type: "object", properties: {}, required: ["missing"] };
    expect(() => CodexInteraction.decode(p, false)).toThrow();
  });

  it("validates fields and cancels questions without answers", () => {
    const p = form();
    p.requestedSchema = { type: "object", properties: { count: { type: "integer", minimum: 1, maximum: 3 }, note: { type: "string", minLength: 2, maxLength: 8 } }, required: ["count"] };
    const decoded = CodexInteraction.decode(p, false);
    for (const value of [0, 1.5, 4, Infinity]) expect(() => decoded.response({ type: "submit", values: { count: numberValue(value) } })).toThrow();
    expect(() => decoded.response({ type: "submit", values: { count: numberValue(2), note: textValue("x") } })).toThrow();
    expect(decoded.response({ type: "submit", values: { count: numberValue(2) } }).action).toBe("accept");
    const question = { id: "q", header: "Choice", question: "Pick", isOther: true, options: [{ label: "One", description: "First" }] };
    const q = CodexInteraction.decode({ questions: [question] }, true);
    expect(((q.response(submit({ q: textValue("Other text") })).answers as Obj).q as Obj).answers).toEqual(["Other text"]);
    expect(q.response({ type: "cancel" }).answers).toEqual({});
    expect(() => q.response({ type: "decline" })).toThrow();
    expect(() => CodexInteraction.decode({ questions: [{ ...question, isSecret: true }] }, true)).toThrow();
    expect(() => CodexInteraction.decode({ questions: [question, question] }, true)).toThrow();
  });

  it("bounds and redacts result details", () => {
    const result = AgentToolDetails.result({ arguments: { secret: "argument-secret" }, result: { _meta: { secret: "metadata-secret" },
      content: [{ type: "image", data: "binary-secret" }, { type: "text", text: "Bearer sensitive-token password=bad" }],
      structuredContent: { access_token: "structured-secret", ok: "done" } } });
    for (const secret of ["argument-secret", "metadata-secret", "binary-secret", "sensitive-token", "structured-secret", "password=bad"]) {
      expect(result.includes(secret)).toBe(false);
    }
    expect(result.includes("done")).toBe(true);
    expect(AgentToolDetails.text("x".repeat(100_000)).length).toBeLessThan(8300);
  });

  it("routes the fixture tool lifecycle, exact responses and duplicates", async () => {
    const harness = new CodexHarness(interactionsFixture);
    try {
      let previous: AgentInteraction | undefined;
      for (const scenario of ["once", "session", "always", "decline", "cancel", "questions", "unsupported", "wrong-thread", "wrong-turn", "tool-failure"]) {
        let requests = 0, unavailable = 0, output = "";
        const activities: CoreToolActivity[] = [];
        const end = untilEnd(harness, (event) => {
          switch (event.type) {
            case "interaction": {
              requests++;
              if (previous) expect(() => harness.respond(previous!.id, submit({ approval: textValue("always") }))).toThrow();
              const response: AgentInteractionResponse = scenario === "decline" ? { type: "decline" } : scenario === "cancel" ? { type: "cancel" }
                : submit({ [scenario === "questions" ? "choice" : "approval"]: textValue(scenario === "questions" ? "North" : scenario === "tool-failure" ? "once" : scenario) });
              harness.respond(event.interaction.id, response);
              expect(() => harness.respond(event.interaction.id, response)).toThrow();
              previous = event.interaction;
              break;
            }
            case "toolActivity": activities.push(event.tool); break;
            case "interactionUnavailable": unavailable++; break;
            case "textDelta": output += event.text; break;
            case "failed": throw new Error(event.text);
          }
        });
        await harness.send(scenario, undefined, "/tmp");
        await within(end, 5000, scenario);
        expect(requests, scenario).toBe(["unsupported", "wrong-thread", "wrong-turn"].includes(scenario) ? 0 : 1);
        expect(unavailable).toBe(scenario === "unsupported" ? 1 : 0);
        expect(activities.length, scenario).toBe(3);
        expect(new Set(activities.map((a) => a.id)).size).toBe(1);
        expect(activities.at(-1)?.state).toBe(scenario === "tool-failure" ? "failed" : "completed");
        const response = JSON.parse(output);
        if (["once", "session", "always"].includes(scenario)) expect(response.content).toEqual({ approval: scenario });
        if (scenario === "unsupported") expect(response.action).toBe("decline");
      }
    } finally { harness.shutdown(); }
  });

  it("carries metadata scopes through the app server", async () => {
    const harness = new CodexHarness(interactionsFixture);
    try {
      let previous: AgentInteraction | undefined;
      for (const scope of ["once", "session", "always"]) {
        let output = "", count = 0;
        const end = untilEnd(harness, (event) => {
          if (event.type === "interaction") {
            count++;
            expect(interactionValidationError(event.interaction, {})).toBeDefined();
            if (previous) expect(() => harness.respond(previous!.id, { type: "cancel" })).toThrow();
            harness.respond(event.interaction.id, submit({ [event.interaction.fields[0].id]: textValue(scope) }));
            previous = event.interaction;
          }
          if (event.type === "textDelta") output += event.text;
          if (event.type === "failed") throw new Error(event.text);
        });
        await harness.send("metadata-" + scope, undefined, "/tmp");
        await within(end, 5000);
        expect(count).toBe(1);
        const result = JSON.parse(output);
        expect(result.action).toBe("accept");
        expect(result.content).toEqual({});
        expect(result._meta?.persist).toBe(scope === "once" ? undefined : scope);
      }
    } finally { harness.shutdown(); }
  });

  it("invalidates on provider resolution, interrupt, disconnect and shutdown", async () => {
    for (const scenario of ["resolved", "wait", "disconnect", "shutdown"]) {
      const harness = new CodexHarness(interactionsFixture);
      const received = deferred<AgentInteraction>(), resolved = deferred();
      harness.onEvent = (event) => {
        if (event.type === "interaction") received.resolve(event.interaction);
        if (event.type === "interactionResolved") resolved.resolve();
      };
      await harness.send(scenario, undefined, "/tmp");
      const request = await within(received.promise, 5000, scenario);
      if (scenario === "wait") await harness.interrupt();
      if (scenario === "shutdown") harness.shutdown();
      await within(resolved.promise, 5000, scenario);
      expect(() => harness.respond(request.id, submit({ approval: textValue("always") }))).toThrow();
      harness.shutdown();
    }
  });

  it("keeps concurrent connections from answering each other's requests", async () => {
    const first = new CodexHarness(interactionsFixture), second = new CodexHarness(interactionsFixture);
    try {
      const a = deferred<AgentInteraction>(), b = deferred<AgentInteraction>();
      first.onEvent = (e) => { if (e.type === "interaction") a.resolve(e.interaction); };
      second.onEvent = (e) => { if (e.type === "interaction") b.resolve(e.interaction); };
      await first.send("wait", undefined, "/tmp");
      await second.send("wait", undefined, "/tmp");
      const [one, two] = await within(Promise.all([a.promise, b.promise]), 5000);
      expect(one.id).not.toBe(two.id);
      expect(() => first.respond(two.id, { type: "cancel" })).toThrow();
      expect(() => second.respond(one.id, { type: "cancel" })).toThrow();
      first.respond(one.id, { type: "decline" });
      second.respond(two.id, { type: "cancel" });
    } finally { first.shutdown(); second.shutdown(); }
  });

  it("cannot launch the server after shutdown during the version probe", async () => {
    const root = temporaryRoot(); roots.push(root);
    const script = executable(root, "fixture", dedent(`
      #!/usr/bin/python3
      import sys, time, pathlib
      root = pathlib.Path(__file__).parent
      if '--version' in sys.argv:
          (root / 'probing').touch()
          time.sleep(.2)
          print('codex-cli 0.158.0')
      else:
          (root / 'launched').touch()
    `));
    const harness = new CodexHarness(script);
    const send = harness.send("fixture", undefined, root);
    for (let i = 0; i < 100 && !existsSync(join(root, "probing")); i++) await sleep(10);
    harness.shutdown();
    await expect(send).rejects.toThrow();
    expect(existsSync(join(root, "launched"))).toBe(false);
  });
});

