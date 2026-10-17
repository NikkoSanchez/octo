import XCTest
import OctoCore
@testable import OctoAgents

final class InteractionTests: XCTestCase {
    private var form: [String: Any] { ["mode": "form", "message": "Allow ChatGPT to use Safari?", "serverName": "computer-use", "threadId": "thread", "turnId": "turn", "_meta": ["app_name": "Safari", "persist": ["session", "always"]], "requestedSchema": ["type": "object", "properties": ["approval": ["type": "string", "oneOf": [["const": "once", "title": "Allow once"], ["const": "session", "title": "This session"], ["const": "always", "title": "Always allow Safari"]]]], "required": ["approval"]]] }
    func testExactAppChoicesAndExplicitConsent() throws {
        let decoded = try CodexInteraction.decode(form, questions: false)
        XCTAssertEqual(decoded.request.target, "Safari")
        XCTAssertEqual(decoded.request.fields[0].options.map(\.id), ["once", "session", "always"])
        XCTAssertNotNil(decoded.request.validationError([:]))
        for choice in ["once", "session", "always"] {
            let result = try decoded.response(.submit(["approval": .text(choice)]))
            XCTAssertEqual(result["action"] as? String, "accept")
            XCTAssertEqual(result["content"] as? [String: String], ["approval": choice])
            XCTAssertEqual((result["_meta"] as? [String: String])?["persist"], choice == "once" ? nil : choice)
        }
        XCTAssertThrowsError(try decoded.response(.submit(["approval": .text("permanent")])))
        XCTAssertThrowsError(try decoded.response(.submit(["approval": .boolean(true)])))
        XCTAssertThrowsError(try decoded.response(.submit(["approval": .text("once"), "extra": .boolean(true)])))
        XCTAssertEqual(try decoded.response(.decline)["action"] as? String, "decline")
        XCTAssertEqual(try decoded.response(.cancel)["action"] as? String, "cancel")
        XCTAssertTrue(try decoded.response(.cancel)["content"] is NSNull)
    }
    private var metadataForm: [String: Any] {
        ["mode": "form", "message": "Allow Computer Use to use Safari?",
         "_meta": ["codex_approval_kind": "mcp_tool_call", "connector_id": "computer-use",
                   "tool_name": "get_app_state", "tool_params": ["app": "com.apple.Safari"],
                   "tool_params_display": [["name": "app", "value": "Safari"]], "persist": ["session", "always"]],
         "requestedSchema": ["type": "object", "properties": [String: Any]()]]
    }
    func testComputerUseMetadataScopesReturnExactMetadataAndEmptyContent() throws {
        let decoded = try CodexInteraction.decode(metadataForm, questions: false)
        XCTAssertEqual(decoded.request.target, "Safari (com.apple.Safari)")
        let field = try XCTUnwrap(decoded.request.fields.first)
        XCTAssertEqual(field.options.map(\.id), ["once", "session", "always"])
        XCTAssertThrowsError(try decoded.response(.submit([:])), "Consent must be explicit")
        for scope in ["once", "session", "always"] {
            let result = try decoded.response(.submit([field.id: .text(scope)]))
            XCTAssertEqual(result["action"] as? String, "accept")
            XCTAssertEqual((result["content"] as? [String: String])?.count, 0, "Synthetic UI field is never sent to the server")
            XCTAssertEqual((result["_meta"] as? [String: String])?["persist"], scope == "once" ? nil : scope)
        }
        for response: AgentInteractionResponse in [.decline, .cancel] {
            let result = try decoded.response(response)
            XCTAssertTrue(result["content"] is NSNull)
            XCTAssertNil(result["_meta"])
        }
    }
    func testMetadataScopeRestrictionsAndSessionOnlyProvider() throws {
        var form = metadataForm
        var meta = try XCTUnwrap(form["_meta"] as? [String: Any])
        meta["persist"] = ["session"]; form["_meta"] = meta
        let decoded = try CodexInteraction.decode(form, questions: false)
        let field = try XCTUnwrap(decoded.request.fields.first)
        XCTAssertEqual(field.options.map(\.id), ["once", "session"])
        XCTAssertThrowsError(try decoded.response(.submit([field.id: .text("always")])))
        for (key, value): (String, Any) in [
            ("persist", ["session", "unknown"]), ("persist", "session"), ("persist", ["session", "session"]),
            ("connector_id", "another-tool"), ("codex_approval_kind", "unknown"),
            ("tool_params", ["app": ""]), ("tool_name", "")
        ] {
            var invalid = meta; invalid[key] = value; form["_meta"] = invalid
            XCTAssertTrue(try CodexInteraction.decode(form, questions: false).request.fields.isEmpty)
        }
        form = metadataForm
        form["requestedSchema"] = ["type": "object", "properties": ["approval": ["type": "string", "enum": ["once"]]], "required": ["approval"]]
        let constrained = try CodexInteraction.decode(form, questions: false)
        XCTAssertEqual(constrained.request.fields.count, 1)
        XCTAssertEqual(constrained.request.fields[0].options.map(\.id), ["once"])
        XCTAssertNil(try constrained.response(.submit(["approval": .text("once")]))["_meta"])
    }
    func testMetadataCannotBroadenSchemaAndDefaultsNeverConsent() throws {
        var p = form
        p["requestedSchema"] = ["type": "object", "properties": ["approval": ["type": "string", "enum": ["once"], "default": "once"]], "required": ["approval"]]
        var decoded = try CodexInteraction.decode(p, questions: false)
        XCTAssertEqual(decoded.request.fields[0].options.map(\.id), ["once"])
        XCTAssertThrowsError(try decoded.response(.submit([:])))
        XCTAssertNil(try decoded.response(.submit(["approval": .text("once")]))["_meta"])
        p["requestedSchema"] = ["type": "object", "properties": ["always": ["type": "boolean", "title": "Always allow Safari", "default": true]], "required": ["always"]]
        decoded = try CodexInteraction.decode(p, questions: false)
        XCTAssertThrowsError(try decoded.response(.submit([:])))
        XCTAssertEqual((try decoded.response(.submit(["always": .boolean(true)]))["_meta"] as? [String: String])?["persist"], "always")
        XCTAssertNil(try decoded.response(.submit(["always": .boolean(false)]))["_meta"])
        p["requestedSchema"] = ["type": "object", "properties": ["approval": ["type": "string", "enum": ["allow"], "title": NSNull(), "enumNames": NSNull()]], "required": ["approval"]]
        decoded = try CodexInteraction.decode(p, questions: false)
        XCTAssertNil(try decoded.response(.submit(["approval": .text("allow")]))["_meta"], "Generic Allow is never permanent")
    }
    func testRejectsMalformedUnsupportedAndAmbiguousForms() throws {
        for field: [String: Any] in [
            ["type": "string", "pattern": ".*"], ["type": "object"], ["type": "array"],
            ["type": "string", "format": "email"], ["type": "string", "enum": ["a", "a"]],
            ["type": "string", "enum": []], ["type": "string", "enum": ["a"], "enumNames": ["a", "b"]],
            ["type": "string", "minLength": true], ["type": "string", "minLength": 5, "maxLength": 2],
            ["type": "number", "maximum": "ten"], ["type": "boolean", "enum": ["yes"]]
        ] {
            var p = form; p["requestedSchema"] = ["type": "object", "properties": ["field": field]]
            XCTAssertThrowsError(try CodexInteraction.decode(p, questions: false), "\(field)")
        }
        for mode in ["url", "openai/userVerification", "unknown"] {
            var p = form; p["mode"] = mode; XCTAssertThrowsError(try CodexInteraction.decode(p, questions: false))
        }
        var p = form; p["requestedSchema"] = ["type": "object", "properties": [:], "required": ["missing"]]
        XCTAssertThrowsError(try CodexInteraction.decode(p, questions: false))
    }
    func testFieldValidationAndQuestionCancellation() throws {
        var p = form
        p["requestedSchema"] = ["type": "object", "properties": ["count": ["type": "integer", "minimum": 1, "maximum": 3], "note": ["type": "string", "minLength": 2, "maxLength": 8]], "required": ["count"]]
        let decoded = try CodexInteraction.decode(p, questions: false)
        for value in [0.0, 1.5, 4.0, .infinity] { XCTAssertThrowsError(try decoded.response(.submit(["count": .number(value)]))) }
        XCTAssertThrowsError(try decoded.response(.submit(["count": .number(2), "note": .text("x")])))
        XCTAssertEqual(try decoded.response(.submit(["count": .number(2)]))["action"] as? String, "accept")
        let question: [String: Any] = ["id": "q", "header": "Choice", "question": "Pick", "isOther": true, "options": [["label": "One", "description": "First"]]]
        let q = try CodexInteraction.decode(["questions": [question]], questions: true)
        XCTAssertEqual((try q.response(.submit(["q": .text("Other text")]))["answers"] as? [String: [String: [String]]])?["q"]?["answers"], ["Other text"])
        XCTAssertEqual((try q.response(.cancel)["answers"] as? [String: String])?.count, 0)
        XCTAssertThrowsError(try q.response(.decline))
        var secret = question; secret["isSecret"] = true
        XCTAssertThrowsError(try CodexInteraction.decode(["questions": [secret]], questions: true))
        XCTAssertThrowsError(try CodexInteraction.decode(["questions": [question, question]], questions: true))
    }
    func testBoundedRedactedResultDetailsAndCapabilities() throws {
        let result = AgentToolDetails.result(["arguments": ["secret": "argument-secret"], "result": ["_meta": ["secret": "metadata-secret"], "content": [["type": "image", "data": "binary-secret"], ["type": "text", "text": "Bearer sensitive-token password=bad"]], "structuredContent": ["access_token": "structured-secret", "ok": "done"]]])
        for secret in ["argument-secret", "metadata-secret", "binary-secret", "sensitive-token", "structured-secret", "password=bad"] { XCTAssertFalse(result.contains(secret)) }
        XCTAssertTrue(result.contains("done"))
        XCTAssertLessThan(AgentToolDetails.text(String(repeating: "x", count: 100_000)).count, 8300)
    }
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/codex-interactions.py") }

    @MainActor func testFixtureToolLifecycleRoutingExactResponseAndDuplicates() async throws {
        let harness = CodexHarness(executable: fixture); defer { harness.shutdown() }
        var previous: AgentInteraction?
        for scenario in ["once", "session", "always", "decline", "cancel", "questions", "unsupported", "wrong-thread", "wrong-turn", "tool-failure"] {
            let done = expectation(description: scenario)
            var requests = 0, unavailable = 0, activities: [ToolActivity] = [], output = ""
            harness.onEvent = { event in
                switch event {
                case .interaction(let request):
                    requests += 1
                    if let previous { do { try harness.respond(to: previous.id, with: .submit(["approval": .text("always")])); XCTFail("Stale response accepted") } catch {} }
                    let response: AgentInteractionResponse = scenario == "decline" ? .decline : scenario == "cancel" ? .cancel : .submit([scenario == "questions" ? "choice" : "approval": .text(scenario == "questions" ? "North" : scenario == "tool-failure" ? "once" : scenario)])
                    do { try harness.respond(to: request.id, with: response) } catch { XCTFail(error.localizedDescription) }
                    do { try harness.respond(to: request.id, with: response); XCTFail("Duplicate response accepted") } catch {}
                    previous = request
                case .toolActivity(let activity): activities.append(activity)
                case .interactionUnavailable: unavailable += 1
                case .textDelta(let delta): output += delta
                case .finished, .interrupted: done.fulfill()
                case .failed(let message): XCTFail(message); done.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: scenario, sessionID: nil, directory: "/tmp")
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(requests, ["unsupported", "wrong-thread", "wrong-turn"].contains(scenario) ? 0 : 1)
            XCTAssertEqual(unavailable, scenario == "unsupported" ? 1 : 0)
            XCTAssertEqual(activities.count, 3, "Start, progress, completion without duplicates/late progress")
            XCTAssertEqual(Set(activities.map(\.id)).count, 1)
            XCTAssertEqual(activities.last?.state, scenario == "tool-failure" ? .failed : .completed)
            let response = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            if ["once", "session", "always"].contains(scenario) { XCTAssertEqual(response?["content"] as? [String: String], ["approval": scenario]) }
            if scenario == "unsupported" { XCTAssertEqual(response?["action"] as? String, "decline") }
        }
    }
    @MainActor func testMetadataScopesThroughAppServer() async throws {
        let harness = CodexHarness(executable: fixture); defer { harness.shutdown() }
        var previous: AgentInteraction?
        for scope in ["once", "session", "always"] {
            let done = expectation(description: scope)
            var output = "", count = 0
            harness.onEvent = { event in
                switch event {
                case .interaction(let request):
                    count += 1
                    XCTAssertNotNil(request.validationError([:]))
                    if let previous { do { try harness.respond(to: previous.id, with: .cancel); XCTFail("Stale request accepted") } catch {} }
                    do {
                        let field = try XCTUnwrap(request.fields.first)
                        try harness.respond(to: request.id, with: .submit([field.id: .text(scope)]))
                    } catch { XCTFail(error.localizedDescription) }
                    previous = request
                case .textDelta(let delta): output += delta
                case .finished, .interrupted: done.fulfill()
                case .failed(let message): XCTFail(message); done.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: "metadata-" + scope, sessionID: nil, directory: "/tmp")
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(count, 1)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(result["action"] as? String, "accept")
            XCTAssertEqual((result["content"] as? [String: String])?.count, 0)
            XCTAssertEqual((result["_meta"] as? [String: String])?["persist"], scope == "once" ? nil : scope)
        }
    }

    @MainActor func testProviderResolutionInterruptDisconnectAndShutdownInvalidate() async throws {
        for scenario in ["resolved", "wait", "disconnect", "shutdown"] {
            let harness = CodexHarness(executable: fixture)
            let received = expectation(description: "request"), resolved = expectation(description: "resolution")
            var request: AgentInteraction?
            harness.onEvent = { event in
                switch event {
                case .interaction(let value): request = value; received.fulfill()
                case .interactionResolved: resolved.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: scenario, sessionID: nil, directory: "/tmp")
            await fulfillment(of: [received], timeout: 5)
            if scenario == "wait" { await harness.interrupt() }
            if scenario == "shutdown" { harness.shutdown() }
            await fulfillment(of: [resolved], timeout: 5)
            let id = try XCTUnwrap(request?.id)
            XCTAssertThrowsError(try harness.respond(to: id, with: .submit(["approval": .text("always")])))
            harness.shutdown()
        }
    }
    @MainActor func testConcurrentConnectionsCannotAnswerEachOthersRequests() async throws {
        let first = CodexHarness(executable: fixture), second = CodexHarness(executable: fixture)
        defer { first.shutdown(); second.shutdown() }
        let gotFirst = expectation(description: "first request"), gotSecond = expectation(description: "second request")
        var a: AgentInteraction?, b: AgentInteraction?
        first.onEvent = { if case .interaction(let request) = $0 { a = request; gotFirst.fulfill() } }
        second.onEvent = { if case .interaction(let request) = $0 { b = request; gotSecond.fulfill() } }
        try await first.send(prompt: "wait", sessionID: nil, directory: "/tmp")
        try await second.send(prompt: "wait", sessionID: nil, directory: "/tmp")
        await fulfillment(of: [gotFirst, gotSecond], timeout: 5)
        let one = try XCTUnwrap(a), two = try XCTUnwrap(b)
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertThrowsError(try first.respond(to: two.id, with: .cancel))
        XCTAssertThrowsError(try second.respond(to: one.id, with: .cancel))
        try first.respond(to: one.id, with: .decline)
        try second.respond(to: two.id, with: .cancel)
    }
    @MainActor func testShutdownDuringVersionProbeCannotLaunchServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture")
        try #"""
        #!/usr/bin/python3
        import sys, time, pathlib
        root = pathlib.Path(__file__).parent
        if '--version' in sys.argv:
            (root / 'probing').touch()
            time.sleep(.2)
            print('codex-cli 0.158.0')
        else:
            (root / 'launched').touch()
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let harness = CodexHarness(executable: executable)
        let send = Task { try await harness.send(prompt: "fixture", sessionID: nil, directory: root.path) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("probing").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        harness.shutdown()
        do { try await send.value; XCTFail("Cancelled startup succeeded") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
    }

}
