import { afterEach, describe, expect, it } from "vitest";
import { CodexHarness, decodeCodexUsage, remainingPercent, windowTitle, type AgentEvent } from "../src";
import { makeImage, type AgentPermissionMode } from "@octo/core";
import { dedent, executable, removeRoot, temporaryRoot, untilEnd, within } from "./helpers";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("CodexHarness", () => {
  it("decodes usage windows and keeps unknown values unknown", () => {
    const usage = decodeCodexUsage({
      rateLimits: { primary: { usedPercent: 99 } },
      rateLimitsByLimitId: {
        codex: { limitName: "Codex", primary: { usedPercent: 21, windowDurationMins: 300, resetsAt: 1_800_000_000 }, secondary: { usedPercent: 47, windowDurationMins: 10080 } },
        other: { primary: { usedPercent: null, windowDurationMins: 43200 } },
      },
    });
    expect(usage.buckets.length).toBe(2);
    const windows = usage.buckets[0].windows;
    expect(remainingPercent(windows[0])).toBe(79);
    expect(windowTitle(windows[0])).toBe("5-hour window");
    expect(windows[0].resetsAt).toBe(1_800_000_000_000);
    expect(windowTitle(windows[1])).toBe("Weekly");
    expect(windows[1].resetsAt).toBeUndefined();
    expect(remainingPercent(usage.buckets[1].windows[0])).toBeUndefined();
    expect(windowTitle(usage.buckets[1].windows[0])).toBe("30-day window");
    expect(() => decodeCodexUsage({})).toThrow();
    expect(remainingPercent(decodeCodexUsage({ rateLimits: { primary: { usedPercent: 120 } } }).buckets[0].windows[0])).toBe(0);
    expect(CodexHarness.supportsAutoReview("codex-cli 0.151.0")).toBe(false);
    expect(CodexHarness.supportsAutoReview("codex-cli 0.158.0-alpha.2")).toBe(true);
    expect(CodexHarness.supportsAutoReview("unknown")).toBe(false);
  });

  it("applies permissions on new, resumed and subsequent turns and reads usage read-only", async () => {
    const root = temporaryRoot(); roots.push(root);
    const script = executable(root, "codex-fixture", dedent(`
      #!/usr/bin/python3
      import sys, json
      if '--version' in sys.argv:
          print('codex-cli 0.158.0-alpha.2'); sys.exit(0)
      def emit(value): print(json.dumps(value), flush=True)
      turn = 0
      for line in sys.stdin:
          obj = json.loads(line)
          method, p = obj.get('method'), obj.get('params', {})
          if method == 'initialize': emit(dict(id=obj['id'], result={}))
          elif method == 'account/rateLimits/read':
              emit(dict(id=obj['id'], result=dict(rateLimits=dict(primary=dict(usedPercent=25, windowDurationMins=10080, resetsAt=1800000000)))))
          elif method in ('thread/start', 'thread/resume'):
              assert p['sandbox'] == 'workspace-write'
              assert p['approvalPolicy'] == 'on-request'
              assert p['approvalsReviewer'] == 'user'
              emit(dict(id=obj['id'], result=dict(thread=dict(id='fixture'))))
          elif method == 'turn/start':
              expected = [('workspaceWrite', 'on-request', 'user'), ('workspaceWrite', 'on-request', 'auto_review'),
                          ('dangerFullAccess', 'never', 'user'), ('readOnly', 'never', 'user'), ('workspaceWrite', 'on-request', 'user')][turn]
              assert (p['sandboxPolicy']['type'], p['approvalPolicy'], p['approvalsReviewer']) == expected
              if expected[0] != 'dangerFullAccess': assert p['sandboxPolicy']['networkAccess'] is False
              if expected[0] == 'workspaceWrite': assert p['sandboxPolicy']['writableRoots'] == [p['cwd']]
              turn += 1
              emit(dict(id=obj['id'], result=dict(turn=dict(id=str(turn)))))
              emit(dict(method='item/reasoning/summaryTextDelta', params=dict(threadId='fixture', itemId='reason', delta='Summary')))
              emit(dict(method='item/completed', params=dict(item=dict(id='reason', type='reasoning', summary=['Summary']))))
              emit(dict(method='account/rateLimits/updated', params=dict(rateLimits=dict(limitId='codex', primary=dict(usedPercent=40)))))
              emit(dict(method='turn/completed', params=dict(turn=dict(id=str(turn), status='completed'))))
          elif method not in ('initialized', None): raise AssertionError(method)
    `));
    const usage = await CodexHarness.usage(root, script);
    expect(remainingPercent(usage.buckets[0].windows[0])).toBe(75);
    for (const session of [undefined, "fixture"]) {
      const harness = new CodexHarness(script);
      try {
        for (const mode of ["ask", "autoReview", "fullAccess", "readOnly", undefined] as (AgentPermissionMode | undefined)[]) {
          let reasoning = "", remaining: number | undefined;
          const end = untilEnd(harness, (event) => {
            if (event.type === "reasoningDelta") reasoning += event.text;
            if (event.type === "usage") remaining = remainingPercent(event.usage.buckets[0].windows[0]);
          });
          await harness.send("fixture", session, root, { permissionMode: mode });
          const result = await within(end, 10000);
          expect(result).toEqual({ type: "finished" });
          expect(reasoning).toBe("Summary");
          expect(remaining).toBe(60);
        }
      } finally { harness.shutdown(); }
    }
  });

  it("paginates the catalog and applies settings on resumed and subsequent turns", async () => {
    const root = temporaryRoot(); roots.push(root);
    const script = executable(root, "codex-fixture", dedent(`
      #!/usr/bin/python3
      import sys, json, base64
      def emit(obj):
          print(json.dumps(obj), flush=True)
      def model(name, hidden=False):
          return dict(model=name, displayName=name, description='', hidden=hidden, isDefault=False,
                      defaultReasoningEffort='medium', supportedReasoningEfforts=[dict(reasoningEffort='high', description='More reasoning')])
      turn = 0
      for line in sys.stdin:
          obj = json.loads(line)
          method, p = obj.get('method'), obj.get('params', {})
          if method == 'initialize':
              emit({'id': obj['id'], 'result': {}})
          elif method == 'model/list':
              assert p['includeHidden'] is False
              if p.get('cursor') == 'page2':
                  result = dict(data=[model('b'), model('a')], nextCursor=None)
              else:
                  result = dict(data=[model('a'), model('hidden', True)], nextCursor='page2')
              emit({'id': obj['id'], 'result': result})
          elif method == 'thread/resume':
              assert p['threadId'] == 'existing-session'
              assert p['model'] == 'a'
              assert p['sandbox'] == 'workspace-write'
              assert p['approvalPolicy'] == 'on-request'
              emit({'id': obj['id'], 'result': {'thread': {'id': 'existing-session'}}})
          elif method == 'turn/start':
              assert p['model'] == ('a' if turn == 0 else 'b')
              assert p['effort'] == ('high' if turn == 0 else 'low')
              assert p['input'][-1]['type'] == 'image'
              assert base64.b64decode(p['input'][-1]['url'].split(',')[1]) == b'fixture-image'
              assert len(p['input']) == (2 if turn == 0 else 1)
              turn += 1
              emit({'id': obj['id'], 'result': {'turn': {'id': str(turn)}}})
              emit({'method': 'turn/completed', 'params': {'turn': {'id': str(turn), 'status': 'completed'}}})
          elif method not in ('initialized', None):
              raise AssertionError('Unexpected request: ' + method)
    `));
    const models = await CodexHarness.models(root, script);
    expect(models.map((m) => m.model)).toEqual(["a", "b"]);
    expect(models[0].supportedReasoningEfforts[0].reasoningEffort).toBe("high");
    const harness = new CodexHarness(script);
    try {
      for (const settings of [{ model: "a", reasoningEffort: "high" }, { model: "b", reasoningEffort: "low" }]) {
        const end = untilEnd(harness);
        await harness.send(settings.model === "a" ? "fixture" : "", "existing-session", root, settings, [makeImage(Buffer.from("fixture-image").toString("base64"))]);
        expect(await within(end, 10000)).toEqual({ type: "finished" });
      }
    } finally { harness.shutdown(); }
  });

  it("streams, approves and completes without duplicating text", async () => {
    const root = temporaryRoot(); roots.push(root);
    const script = executable(root, "codex-fixture", dedent(`
      #!/usr/bin/python3
      import sys, json, time
      def emit(obj):
          value = json.dumps(obj) + '\\n'
          sys.stdout.write(value[:7]); sys.stdout.flush(); time.sleep(.002)
          sys.stdout.write(value[7:]); sys.stdout.flush()
      for line in sys.stdin:
          obj = json.loads(line)
          method = obj.get('method')
          if method == 'initialize':
              emit({'id': obj['id'], 'result': {}})
          elif method == 'thread/start':
              assert obj['params']['sandbox'] == 'workspace-write'
              assert obj['params']['approvalPolicy'] == 'on-request'
              emit({'id': obj['id'], 'result': {'thread': {'id': 'thread-fixture'}}})
          elif method == 'turn/start':
              emit({'id': obj['id'], 'result': {'turn': {'id': 'turn-fixture'}}})
              emit({'method': 'item/started', 'params': {'item': {'id': 'progress-1', 'type': 'agentMessage', 'phase': 'commentary'}}})
              emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-fixture', 'itemId': 'progress-1', 'delta': 'Inspecting files'}})
              emit({'method': 'item/completed', 'params': {'item': {'id': 'progress-1', 'type': 'agentMessage', 'phase': 'commentary', 'text': 'Inspecting files'}}})
              emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-fixture', 'itemId': 'message-1', 'delta': 'Hello 🐙'}})
              emit({'method': 'item/completed', 'params': {'item': {'id': 'message-1', 'type': 'agentMessage', 'text': 'Hello 🐙'}}})
              emit({'id': 400, 'method': 'item/commandExecution/requestApproval', 'params': {'command': 'echo fixture', 'cwd': '/tmp'}})
          elif obj.get('id') == 400:
              assert obj['result']['decision'] == 'accept'
              emit({'method': 'turn/completed', 'params': {'turn': {'id': 'turn-fixture', 'status': 'completed'}}})
    `));
    const harness = new CodexHarness(script);
    try {
      let output = "", activity = "", session: string | undefined, approved = false;
      const end = untilEnd(harness, (event: AgentEvent) => {
        if (event.type === "session") session = event.id;
        if (event.type === "activity" || event.type === "activityDelta") activity += event.text;
        if (event.type === "textDelta" || event.type === "message") output += event.text;
        if (event.type === "approval") { approved = true; event.approval.respond(true); }
      });
      await harness.send("fixture", undefined, root);
      expect(await within(end, 10000)).toEqual({ type: "finished" });
      expect(session).toBe("thread-fixture");
      expect(output).toBe("Hello 🐙");
      expect(approved).toBe(true);
      expect(activity).toBe("Inspecting files");
    } finally { harness.shutdown(); }
  });
});
