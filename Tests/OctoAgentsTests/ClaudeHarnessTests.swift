import XCTest
import OctoCore
@testable import OctoAgents

@MainActor final class ClaudeHarnessTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/fixtures/claude-stream.py")
    }
    func testDiscoverySettingsAndPermissionBoundaries() async throws {
        let models = try await ClaudeHarness.models(directory: "/tmp", executable: fixture)
        XCTAssertEqual(models.map(\.model), ["default", "sonnet", "haiku"])
        XCTAssertEqual(models[1].supportedReasoningEfforts.map(\.reasoningEffort), ["low", "high"])
        XCTAssertTrue(models[2].supportedReasoningEfforts.isEmpty)
        XCTAssertEqual(models[1].defaultReasoningEffort, "", "Do not invent a model's default effort")
        let args = try ClaudeHarness.arguments(settings: .init(model: "sonnet", reasoningEffort: "high", permissionMode: .ask), sessionID: "--dangerously-skip-permissions")
        XCTAssertTrue(args.contains("--resume=--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        for mode in [AgentPermissionMode.readOnly, .fullAccess] {
            XCTAssertThrowsError(try ClaudeHarness.arguments(settings: .init(permissionMode: mode), sessionID: nil))
        }
        XCTAssertThrowsError(try ClaudeHarness.decodeModels([:]))
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        do {
            try await harness.send(prompt: "unsent", sessionID: nil, directory: "/tmp", settings: .init(model: "haiku", reasoningEffort: "high"))
            XCTFail("Unsupported model effort must fail before submitting input")
        } catch { XCTAssertTrue(error.localizedDescription.contains("effort")) }
    }
    func testPermissionConfirmationRejectsUnavailableAndBroaderModes() throws {
        try ClaudeHarness.validatePermissions(["current_permission_mode": "auto"], settings: .init())
        for mode in ["default", "manual"] {
            try ClaudeHarness.validatePermissions(["current_permission_mode": mode], settings: .init(permissionMode: .ask))
            XCTAssertThrowsError(try ClaudeHarness.validatePermissions(["current_permission_mode": mode], settings: .init()))
        }
        XCTAssertThrowsError(try ClaudeHarness.validatePermissions([:], settings: .init()))
        XCTAssertThrowsError(try ClaudeHarness.validatePermissions(["current_permission_mode": "bypassPermissions"], settings: .init(permissionMode: .autoReview)))
        XCTAssertThrowsError(try ClaudeHarness.validatePermissions(["current_permission_mode": "auto"], settings: .init(permissionMode: .ask)))
        try ClaudeHarness.validatePermissions([:], settings: .init(permissionMode: .ask))
    }
    func testAutoDefaultAndPermissionTransitionsOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"trace":true}"#.write(to: root.appendingPathComponent(".claude-fixture-permissions.json"), atomically: true, encoding: .utf8)
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        for (index, mode) in ([nil, .ask, .autoReview] as [AgentPermissionMode?]).enumerated() {
            let done = expectation(description: "permission turn \(index)")
            harness.onEvent = { event in
                if case .finished = event { done.fulfill() }
                if case .failed(let error) = event { XCTFail(error); done.fulfill() }
            }
            try await harness.send(prompt: "permissions", sessionID: index == 0 ? nil : "fixture-session", directory: root.path, settings: .init(permissionMode: mode))
            await fulfillment(of: [done], timeout: 5)
        }
        let frames = try String(contentsOf: root.appendingPathComponent(".claude-fixture-trace.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let arguments = frames.compactMap { $0["argv"] as? [String] }
        XCTAssertEqual(arguments.map { $0[$0.firstIndex(of: "--permission-mode")! + 1] }, ["auto", "manual", "auto"])
        XCTAssertFalse(arguments[0].contains("--resume=fixture-session"))
        XCTAssertTrue(arguments.dropFirst().allSatisfy { $0.contains("--resume=fixture-session") })
        XCTAssertEqual(frames.filter { $0["type"] as? String == "user" }.count, 3)
    }
    func testUnavailableAutoDoesNotSubmitPromptAndDiscoveryRemainsAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"reported_mode":"default"}"#.write(to: root.appendingPathComponent(".claude-fixture-permissions.json"), atomically: true, encoding: .utf8)
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        do {
            try await harness.send(prompt: "must stay unsent", sessionID: "fixture-session", directory: root.path)
            XCTFail("An unavailable Auto mode must fail before prompt submission")
        } catch { XCTAssertTrue(error.localizedDescription.contains("did not enable")) }
        let models = try await ClaudeHarness.models(directory: root.path, executable: fixture)
        XCTAssertFalse(models.isEmpty)
        let frames = try String(contentsOf: root.appendingPathComponent(".claude-fixture-trace.jsonl"), encoding: .utf8)
        XCTAssertFalse(frames.contains("must stay unsent"))
    }
    func testRuntimePermissionFallbackIsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"runtime_mode":"default"}"#.write(to: root.appendingPathComponent(".claude-fixture-permissions.json"), atomically: true, encoding: .utf8)
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        let done = expectation(description: "fallback")
        var notices: [String] = []
        harness.onEvent = { event in
            if case .interactionUnavailable(let text) = event { notices.append(text) }
            if case .finished = event { done.fulfill() }
            if case .failed(let error) = event { XCTFail(error); done.fulfill() }
        }
        try await harness.send(prompt: "permissions", sessionID: nil, directory: root.path)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("changed its permission mode") == true)
    }
    func testFragmentedStreamingResumeImagesApprovalsAndToolDeduplication() async throws {
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        for (index, prompt) in ["stream", "image"].enumerated() {
            let done = expectation(description: "result \(index)")
            var output = "", session: String?, tools: [ToolActivity] = [], approvals = 0, finishes = 0
            harness.onEvent = { event in
                switch event {
                case .textDelta(let text), .message(let text): output += text
                case .session(let id): session = id
                case .toolActivity(let tool): tools.append(tool)
                case .approval(let approval): approvals += 1; approval.respond(index == 0); approval.respond(true)
                case .finished: finishes += 1; done.fulfill()
                case .failed(let error): XCTFail(error); done.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: prompt == "image" ? "" : prompt, sessionID: index == 0 ? nil : "fixture-session", directory: "/tmp",
                settings: .init(model: "sonnet", reasoningEffort: "high", permissionMode: .ask),
                images: [ImageAttachment(pngData: Data("fixture-image".utf8))])
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(output, "Hello 🐙 again fallback")
            if index == 0 { XCTAssertEqual(session, "fixture-session") }
            XCTAssertEqual(finishes, 1); XCTAssertEqual(approvals, 1)
            XCTAssertEqual(tools.map(\.state), [.running, .completed])
            XCTAssertFalse(tools.last?.detail.contains("secret-value") == true)
        }
    }
    func testQuestionsValidationCancellationAndUnsupportedSchemas() async throws {
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        var staleID: UUID?
        let done = expectation(description: "question finished")
        harness.onEvent = { event in
            switch event {
            case .interaction(let interaction):
                staleID = interaction.id
                do { try harness.respond(to: interaction.id, with: .submit([:])); XCTFail("Required answer missing") } catch { }
                do { try harness.respond(to: interaction.id, with: .submit(["Which option?": .text("B")])) } catch { XCTFail(error.localizedDescription) }
            case .finished: done.fulfill()
            case .failed(let error): XCTFail(error); done.fulfill()
            default: break
            }
        }
        try await harness.send(prompt: "question", sessionID: nil, directory: "/tmp")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertThrowsError(try harness.respond(to: XCTUnwrap(staleID), with: .cancel))
        let unsupported = expectation(description: "unsupported finished")
        var notices = 0
        harness.onEvent = { event in
            if case .interactionUnavailable = event { notices += 1 }
            if case .finished = event { unsupported.fulfill() }
            if case .failed(let error) = event { XCTFail(error); unsupported.fulfill() }
        }
        try await harness.send(prompt: "unsupported", sessionID: nil, directory: "/tmp")
        await fulfillment(of: [unsupported], timeout: 5)
        XCTAssertEqual(notices, 1)
    }
    func testStopInvalidatesApprovalAndDoesNotFinishSuccessfully() async throws {
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        let approvalShown = expectation(description: "approval")
        var pending: AgentApproval?, interrupted = 0, finished = 0, resolved = 0
        harness.onEvent = { event in
            if case .approval(let value) = event { pending = value; approvalShown.fulfill() }
            if case .interrupted = event { interrupted += 1 }
            if case .finished = event { finished += 1 }
            if case .approvalResolved = event { resolved += 1 }
        }
        try await harness.send(prompt: "hold", sessionID: nil, directory: "/tmp")
        await fulfillment(of: [approvalShown], timeout: 5)
        await harness.interrupt(); pending?.respond(true)
        XCTAssertEqual(interrupted, 1); XCTAssertEqual(finished, 0); XCTAssertEqual(resolved, 1)
        let next = expectation(description: "next result")
        harness.onEvent = { event in
            if case .approval(let value) = event { value.respond(false) }
            if case .finished = event { next.fulfill() }
            if case .failed(let error) = event { XCTFail(error); next.fulfill() }
        }
        try await harness.send(prompt: "stream", sessionID: "fixture-session", directory: "/tmp")
        pending?.respond(true)
        await fulfillment(of: [next], timeout: 5)
    }
    func testProviderCancelResolvesCardAndIgnoresLateClick() async throws {
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        let cancelled = expectation(description: "provider cancellation")
        var pending: AgentApproval?
        harness.onEvent = { event in
            if case .approval(let value) = event { pending = value }
            if case .approvalResolved = event { cancelled.fulfill() }
            if case .finished = event { XCTFail("Cancelled request must not respond") }
        }
        try await harness.send(prompt: "cancel-request", sessionID: nil, directory: "/tmp")
        await fulfillment(of: [cancelled], timeout: 5)
        pending?.respond(true)
        await harness.interrupt()
    }
    func testErrorAndUnexpectedCleanExitAreFailures() async throws {
        for prompt in ["error", "disconnect"] {
            let harness = ClaudeHarness(executable: fixture)
            let failure = expectation(description: "failure")
            harness.onEvent = { event in
                if case .failed = event { failure.fulfill() }
                if case .finished = event { XCTFail("Exit without result is not success") }
            }
            try await harness.send(prompt: prompt, sessionID: nil, directory: "/tmp")
            await fulfillment(of: [failure], timeout: 5)
            harness.shutdown()
        }
    }
    func testShutdownDuringInitializationNeverSendsPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("delayed")
        try "#!/usr/bin/python3\nimport time\ntime.sleep(10)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let harness = ClaudeHarness(executable: executable)
        let task = Task { try await harness.send(prompt: "must not send", sessionID: nil, directory: root.path) }
        try await Task.sleep(for: .milliseconds(30))
        harness.shutdown()
        do { try await task.value; XCTFail("Startup must be cancelled") } catch { }
    }
    func testRateLimitEventsBecomeMergedAccountUsage() async throws {
        let harness = ClaudeHarness(executable: fixture)
        defer { harness.shutdown() }
        let done = expectation(description: "rate limit turn")
        var snapshot: AgentUsage?, updates = 0
        harness.onEvent = { event in
            switch event {
            case .usage(let usage): updates += 1; snapshot = AgentUsage.merging(usage, into: snapshot)
            case .finished: done.fulfill()
            case .failed(let error): XCTFail(error); done.fulfill()
            default: break
            }
        }
        try await harness.send(prompt: "ratelimit", sessionID: nil, directory: "/tmp", settings: .init())
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(updates, 2, "Wrong-session and empty events must not produce usage")
        let windows = try XCTUnwrap(snapshot?.buckets.first { $0.id == "claude" }?.windows)
        XCTAssertEqual(windows.map(\.id), ["seven_day", "five_hour"])
        XCTAssertEqual(windows[0].usedPercent ?? 0, 82, accuracy: 0.001)
        XCTAssertEqual(windows[0].title, "Weekly · all models")
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(windows[1].remainingPercent ?? 0, 75, accuracy: 0.001)
        XCTAssertFalse(windows.contains { $0.isLimited })
    }
    func testRateLimitDecodingKeepsUnknownsUnknown() throws {
        XCTAssertNil(ClaudeHarness.decodeRateLimit([:]))
        XCTAssertNil(ClaudeHarness.decodeRateLimit(["status": "allowed"]))
        let rejected = try XCTUnwrap(ClaudeHarness.decodeRateLimit(["status": "rejected", "rateLimitType": "seven_day_opus"]))
        let window = try XCTUnwrap(rejected.buckets.first?.windows.first)
        XCTAssertTrue(window.isLimited)
        XCTAssertNil(window.usedPercent, "A rejection without utilization must not be reported as a percentage")
        XCTAssertNil(window.resetsAt)
        XCTAssertEqual(window.title, "Weekly · Opus")
        let combined = try XCTUnwrap(ClaudeHarness.decodeRateLimit([
            "status": "allowed", "rateLimitType": "five_hour", "utilization": 1.3,
            "unifiedWindows": ["seven_day": ["utilization": 0.4, "resetsAt": 1_800_000_000], "five_hour": ["utilization": 1.3, "resetsAt": 1_790_000_000]]]))
        XCTAssertEqual(combined.buckets[0].windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(combined.buckets[0].windows[0].remainingPercent, 0, "Over-cap utilization clamps remaining at zero")
        XCTAssertEqual(combined.buckets[0].windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_000_000), "Top-level event without reset keeps the window's reset")
        let unknown = try XCTUnwrap(ClaudeHarness.decodeRateLimit(["rateLimitType": "future_window", "utilization": -1]))
        XCTAssertNil(unknown.buckets[0].windows[0].usedPercent)
        XCTAssertNil(unknown.buckets[0].windows[0].durationMinutes)
    }
    func testContextUsageDecodingKeepsUnknownsUnknown() throws {
        let api: [String: Any] = ["input_tokens": 2, "output_tokens": 400, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 60000]
        let response: [String: Any] = ["totalTokens": 61002, "maxTokens": 1_000_000, "autoCompactThreshold": 967_000, "isAutoCompactEnabled": true, "apiUsage": api]
        let session = TokenCounts(total: 9)
        let usage = try XCTUnwrap(ClaudeHarness.decodeContextUsage(response, session: session))
        XCTAssertEqual(usage.usedTokens, 61002, "Occupied context comes from Claude's own accounting, not the response total")
        XCTAssertEqual(usage.latest, TokenCounts(total: 61402, input: 61002, cachedInput: 60000, cacheWriteInput: 1000, output: 400))
        XCTAssertEqual(usage.session, session)
        XCTAssertEqual(usage.contextWindow, 1_000_000)
        XCTAssertEqual(usage.percentUsed, 6)
        XCTAssertEqual(usage.autoCompactThreshold, 967_000)
        XCTAssertNil(ClaudeHarness.decodeContextUsage(response.merging(["apiUsage": NSNull()]) { $1 }, session: nil), "No response yet")
        for invalid: Any in [-1, true, "61002", 1.5] {
            XCTAssertNil(ClaudeHarness.decodeContextUsage(response.merging(["totalTokens": invalid]) { $1 }, session: nil))
        }
        let unknown = try XCTUnwrap(ClaudeHarness.decodeContextUsage(response.merging(["maxTokens": 0, "isAutoCompactEnabled": false]) { $1 }, session: nil))
        XCTAssertNil(unknown.usedFraction)
        XCTAssertNil(unknown.autoCompactThreshold, "A disabled automatic compaction has no threshold")
        XCTAssertNil(unknown.session)
        let huge = try XCTUnwrap(ClaudeHarness.decodeContextUsage(response.merging(["apiUsage": ["input_tokens": Int.max, "output_tokens": Int.max]]) { $1 }, session: nil))
        XCTAssertEqual(huge.latest.total, Int.max, "Untrusted counts saturate instead of overflowing")
    }
    func testSessionTotalsReadOnlyTheNamedMainTranscript() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projects) }
        try writeTranscript(in: projects)
        let other = projects.appendingPathComponent("-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try #"{"type":"assistant","timestamp":"2026-10-16T10:00:00Z","message":{"id":"x","usage":{"input_tokens":999}}}"#
            .write(to: other.appendingPathComponent("another-session.jsonl"), atomically: true, encoding: .utf8)
        let totals = try XCTUnwrap(ClaudeTranscriptUsage.sessionTotals(session: "fixture-session", projectsDirectory: projects))
        XCTAssertEqual(totals, TokenCounts(total: 61557, input: 61107, cachedInput: 60000, cacheWriteInput: 1100, output: 450))
        for session in ["", "../-project/fixture-session", ".hidden", "missing"] {
            XCTAssertNil(ClaudeTranscriptUsage.sessionTotals(session: session, projectsDirectory: projects))
        }
    }
    func testContextUsageAndCompactionStatusAreReported() async throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projects) }
        try writeTranscript(in: projects)
        let harness = ClaudeHarness(executable: fixture, projectsDirectory: projects)
        defer { harness.shutdown() }
        for (prompt, expected) in [("context", ContextCompaction.State.completed), ("compact-failed", .interrupted), ("compact-unfinished", .interrupted)] {
            let done = expectation(description: "\(prompt) finished"), final = expectation(description: "\(prompt) final usage")
            var snapshots: [ConversationUsage] = [], states: [ContextCompaction.State] = [], ids = Set<String>()
            harness.onEvent = { event in
                switch event {
                case .conversationUsage(let usage):
                    snapshots.append(usage)
                    if snapshots.count == 1 { final.fulfill() }
                case .compaction(let compaction): states.append(compaction.state); ids.insert(compaction.id)
                case .finished: done.fulfill()
                case .failed(let error): XCTFail(error); done.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: prompt, sessionID: nil, directory: "/tmp")
            await fulfillment(of: [done, final], timeout: 10)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(states, [.compacting, expected], "\(prompt): duplicate and late status events are ignored")
            XCTAssertEqual(ids.count, 1)
            let usage = try XCTUnwrap(snapshots.last)
            XCTAssertEqual(usage.usedTokens, prompt == "context" ? 12000 : 61002)
            XCTAssertEqual(usage.contextWindow, 1_000_000)
            XCTAssertEqual(usage.autoCompactThreshold, 967_000)
            XCTAssertEqual(usage.session?.total, 61557)
            XCTAssertEqual(usage.latest.total, prompt == "context" ? 155 : 61402)
        }
        let quiet = expectation(description: "no response turn")
        var reported = 0
        harness.onEvent = { event in
            if case .conversationUsage = event { reported += 1 }
            if case .finished = event { quiet.fulfill() }
        }
        try await harness.send(prompt: "permissions", sessionID: "fixture-session", directory: "/tmp")
        await fulfillment(of: [quiet], timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reported, 0, "A process that has not reported a response has no context usage")
    }
    private func writeTranscript(in projects: URL) throws {
        let project = projects.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = #"{"type":"assistant","sessionId":"fixture-session","requestId":"r1","timestamp":"2026-10-16T10:00:00Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":60000,"cache_creation_input_tokens":1000,"output_tokens":400}}}"#
        let second = #"{"type":"assistant","sessionId":"fixture-session","requestId":"r2","timestamp":"2026-10-16T10:01:00Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"output_tokens":50}}}"#
        try [first, first, #"{"type":"user","message":{"content":"usage"}}"#, second].joined(separator: "\n")
            .write(to: project.appendingPathComponent("fixture-session.jsonl"), atomically: true, encoding: .utf8)
    }
}
