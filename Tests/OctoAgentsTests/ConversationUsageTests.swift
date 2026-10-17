import XCTest
import OctoCore
@testable import OctoAgents

final class ConversationUsageTests: XCTestCase {
    @MainActor func testDecodingUnknownCapacityAndInvalidCounts() throws {
        func payload(_ last: [String: Any], capacity: Any = NSNull()) -> [String: Any] {
            ["tokenUsage": ["last": last, "total": ["totalTokens": 900_000], "modelContextWindow": capacity]]
        }
        let usage = try CodexHarness.decodeConversationUsage(payload([
            "totalTokens": 80_000, "inputTokens": 70_000, "cachedInputTokens": 60_000,
            "outputTokens": 10_000, "reasoningOutputTokens": 5_000
        ], capacity: 200_000))
        XCTAssertEqual(usage.percentUsed, 40)
        XCTAssertEqual(usage.remainingTokens, 120_000)
        XCTAssertEqual(usage.session?.total, 900_000)
        XCTAssertEqual(usage.latest.total, 80_000, "Do not add cached or reasoning subsets to total")
        XCTAssertNil(usage.latest.cacheWriteInput)
        for capacity: Any in [NSNull(), 0, -1] {
            let unknown = try CodexHarness.decodeConversationUsage(payload(["totalTokens": 0], capacity: capacity))
            XCTAssertNil(unknown.usedFraction)
            XCTAssertNil(unknown.remainingTokens)
            XCTAssertNil(unknown.latest.input)
        }
        let full = try CodexHarness.decodeConversationUsage(payload(["totalTokens": Int.max], capacity: 1))
        XCTAssertEqual(full.percentUsed, 100)
        XCTAssertEqual(full.remainingTokens, 0)
        for invalid: Any in [-1, true, "123", 1.5] {
            XCTAssertThrowsError(try CodexHarness.decodeConversationUsage(payload(["totalTokens": invalid])))
        }
        XCTAssertThrowsError(try CodexHarness.decodeConversationUsage(payload(["totalTokens": 5, "inputTokens": -1])))
        XCTAssertThrowsError(try CodexHarness.decodeConversationUsage([:]))
    }

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/codex-usage.py")
    }

    @MainActor func testFramedUsageAndCompactionRoutingOnNewResumedAndSubsequentTurns() async throws {
        for session in [nil, "resumed-fixture"] as [String?] {
            let harness = CodexHarness(executable: fixture)
            defer { harness.shutdown() }
            for prompt in ["normal", "unknown"] {
                let done = expectation(description: "turn finished")
                let finalUsage = expectation(description: "late final accounting")
                var snapshots: [ConversationUsage] = [], states: [ContextCompaction.State] = []
                harness.onEvent = { event in
                    switch event {
                    case .conversationUsage(let usage):
                        snapshots.append(usage)
                        if usage.latest.total == 32_000 { finalUsage.fulfill() }
                    case .compaction(let compaction): states.append(compaction.state)
                    case .finished, .interrupted: done.fulfill()
                    case .failed(let error): XCTFail(error)
                    default: break
                    }
                }
                try await harness.send(prompt: prompt, sessionID: session, directory: fixture.deletingLastPathComponent().path)
                await fulfillment(of: [done, finalUsage], timeout: 10)
                XCTAssertEqual(snapshots.map(\.latest.total), [184_000, 184_000, 184_000, 32_000])
                XCTAssertEqual(snapshots.last?.session?.total, 854_000)
                XCTAssertEqual(snapshots.last?.contextWindow, prompt == "unknown" ? nil : 200_000)
                XCTAssertEqual(states, [.compacting, .completed], "Ignore duplicates, stale and wrong-owner lifecycle events")
            }
        }
    }

    @MainActor func testCompactionDisconnectAndInterruptDoNotReportCompletion() async throws {
        for prompt in ["hold", "disconnect"] {
            let harness = CodexHarness(executable: fixture)
            defer { harness.shutdown() }
            let started = expectation(description: "compaction started")
            let ended = expectation(description: "turn ended")
            var states: [ContextCompaction.State] = []
            harness.onEvent = { event in
                switch event {
                case .compaction(let compaction): states.append(compaction.state); started.fulfill()
                case .finished, .interrupted, .failed: ended.fulfill()
                default: break
                }
            }
            try await harness.send(prompt: prompt, sessionID: nil, directory: fixture.deletingLastPathComponent().path)
            await fulfillment(of: [started], timeout: 10)
            if prompt == "hold" { await harness.interrupt() }
            await fulfillment(of: [ended], timeout: 10)
            XCTAssertEqual(states, [.compacting])
        }
    }
}
