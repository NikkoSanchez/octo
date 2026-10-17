import XCTest
import OctoCore
@testable import OctoAgents

@MainActor final class SteeringLifecycleTests: XCTestCase {
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/codex-steering.py") }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func requests(_ root: URL, method: String) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("fixture-rpc.jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
            let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            return value["method"] as? String == method ? value["params"] as? [String: Any] : nil
        }
    }
    func testSteerFramingRejectionQuestionAndCompletionRace() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = CodexHarness(executable: fixture); defer { harness.shutdown() }
        let question = expectation(description: "question"), done = expectation(description: "complete")
        var requests = 0
        harness.onEvent = { event in
            switch event {
            case .interaction: requests += 1; question.fulfill()
            case .finished: done.fulfill()
            case .failed(let text): XCTFail(text)
            default: break
            }
        }
        try await harness.send(prompt: "wait", sessionID: nil, directory: root.path)
        await fulfillment(of: [question], timeout: 5)
        do { try await harness.steer(prompt: "reject"); XCTFail("Expected refusal") } catch {}
        let image = ImageAttachment(name: "fixture", pngData: Data("fixture-image".utf8))
        try await harness.steer(prompt: "Guidance", images: [image])
        XCTAssertEqual(requests, 1)
        try await harness.steer(prompt: "finish before ack")
        await fulfillment(of: [done], timeout: 5)
        let steers = try self.requests(root, method: "turn/steer")
        XCTAssertEqual(steers.count, 3)
        XCTAssertEqual(steers[1]["expectedTurnId"] as? String, "turn-1")
        XCTAssertEqual((steers[1]["input"] as? [[String: Any]])?.last?["url"] as? String, "data:image/png;base64," + image.pngData.base64EncodedString())
        XCTAssertEqual(try self.requests(root, method: "turn/start").count, 1)
        let cleanups = try self.requests(root, method: "mcpServer/tool/call")
        XCTAssertEqual(cleanups.count, 1)
        XCTAssertEqual((cleanups[0]["arguments"] as? [String: String])?["hook_event_name"], "Stop")
        do { try await harness.steer(prompt: "Too late"); XCTFail("Expected idle refusal") } catch {}
    }
    func testCleanupOnCompletionInterruptionAndFailureBeforeNextTurn() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = CodexHarness(executable: fixture); defer { harness.shutdown() }
        var warnings = 0
        for (index, prompt) in ["complete", "hold", "cleanup error", "no tool"].enumerated() {
            let done = expectation(description: prompt)
            harness.onEvent = { event in
                switch event {
                case .finished: XCTAssertNotEqual(prompt, "hold"); done.fulfill()
                case .interrupted: XCTAssertEqual(prompt, "hold"); done.fulfill()
                case .interactionUnavailable: warnings += 1
                case .failed(let text): XCTFail(text); done.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: prompt, sessionID: "fixture", directory: root.path)
            if prompt == "hold" { await harness.interrupt() }
            await fulfillment(of: [done], timeout: 8)
            XCTAssertEqual(try requests(root, method: "mcpServer/tool/call").count, min(index + 1, 3))
        }
        XCTAssertEqual(warnings, 1)
        let cleanups = try requests(root, method: "mcpServer/tool/call")
        XCTAssertEqual((cleanups[1]["arguments"] as? [String: String])?["hook_event_name"], "Interrupt")
        XCTAssertEqual((cleanups[2]["arguments"] as? [String: String])?["turn_id"], "turn-3")
    }
    func testShutdownCleansOnlyItsOwnedComputerUseTurn() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = CodexHarness(executable: fixture)
        let activity = expectation(description: "computer activity")
        harness.onEvent = { if case .toolActivity(let tool) = $0, tool.state == .running { activity.fulfill() } }
        try await harness.send(prompt: "hold", sessionID: nil, directory: root.path)
        await fulfillment(of: [activity], timeout: 5)
        harness.shutdown(); harness.shutdown()
        for _ in 0..<100 {
            if (try? requests(root, method: "mcpServer/tool/call").count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try requests(root, method: "mcpServer/tool/call").count, 1)
        XCTAssertEqual(try requests(root, method: "turn/interrupt").count, 1)
    }
}
