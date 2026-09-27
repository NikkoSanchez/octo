import XCTest
import OctoCore
@testable import OctoAgents

final class CodexHarnessTests: XCTestCase {
    @MainActor func testCatalogPaginationAndSettingsOnResumedAndSubsequentTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("codex-fixture")
        let script = #"""
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
        """#
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let models = try await CodexHarness.models(directory: root.path, executable: fixture)
        XCTAssertEqual(models.map(\.model), ["a", "b"])
        XCTAssertEqual(models[0].supportedReasoningEfforts.first?.reasoningEffort, "high")
        let harness = CodexHarness(executable: fixture)
        defer { harness.shutdown() }
        for settings in [AgentSettings(model: "a", reasoningEffort: "high"), AgentSettings(model: "b", reasoningEffort: "low")] {
            let completed = expectation(description: "turn finished")
            harness.onEvent = { event in
                if case .finished = event { completed.fulfill() }
                if case .failed(let error) = event { XCTFail(error); completed.fulfill() }
            }
            try await harness.send(prompt: settings.model == "a" ? "fixture" : "", sessionID: "existing-session", directory: root.path, settings: settings, images: [ImageAttachment(pngData: Data("fixture-image".utf8))])
            await fulfillment(of: [completed], timeout: 10)
        }
    }

    @MainActor func testProtocolStreamingApprovalAndCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("codex-fixture")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, time
        def emit(obj):
            value = json.dumps(obj) + '\n'
            # Split a frame across writes to exercise transport buffering.
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
                emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-fixture', 'itemId': 'message-1', 'delta': 'Hello 🐙'}})
                emit({'method': 'item/completed', 'params': {'item': {'id': 'message-1', 'type': 'agentMessage', 'text': 'Hello 🐙'}}})
                emit({'id': 400, 'method': 'item/commandExecution/requestApproval', 'params': {'command': 'echo fixture', 'cwd': '/tmp'}})
            elif obj.get('id') == 400:
                assert obj['result']['decision'] == 'accept'
                emit({'method': 'turn/completed', 'params': {'turn': {'id': 'turn-fixture', 'status': 'completed'}}})
        """#
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let harness = CodexHarness(executable: fixture)
        defer { harness.shutdown() }
        let completed = expectation(description: "turn completed")
        var output = "", session: String?, approved = false
        harness.onEvent = { event in
            switch event {
            case .session(let id): session = id
            case .textDelta(let text), .message(let text): output += text
            case .approval(let approval): approved = true; approval.respond(true)
            case .finished: completed.fulfill()
            case .failed(let error): XCTFail(error); completed.fulfill()
            default: break
            }
        }
        try await harness.send(prompt: "fixture", sessionID: nil, directory: root.path)
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(session, "thread-fixture")
        XCTAssertEqual(output, "Hello 🐙", "Completed events must not duplicate streamed text")
        XCTAssertTrue(approved)
    }
}
