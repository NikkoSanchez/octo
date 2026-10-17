import XCTest
import OctoCore
@testable import OctoAgents

final class UsageLedgerTests: XCTestCase {
    private func lines(_ objects: [[String: Any]]) throws -> Data {
        var data = Data()
        for object in objects { data += try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8) }
        return data
    }
    private func claude(_ id: String, request: String = "r", model: String = "claude-opus-5-5", at time: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> [String: Any] {
        ["type": "assistant", "timestamp": time, "sessionId": "s1", "requestId": request,
         "message": ["id": id, "model": model, "usage": ["input_tokens": input, "cache_read_input_tokens": cacheRead,
                                                          "cache_creation_input_tokens": cacheWrite, "output_tokens": output]]]
    }
    private func codex(_ time: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        let usage = ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0, "output_tokens": output]
        return ["timestamp": time, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]
    }

    func testClaudeCountsEachMessageOnceAndSplitsCacheUsage() throws {
        let data = try lines([
            ["type": "user", "timestamp": "2026-10-01T10:00:00Z", "message": ["content": "usage"]],
            claude("m1", at: "2026-10-01T10:01:00.250Z", input: 2, cacheRead: 100, cacheWrite: 50, output: 7),
            // Each content block repeats the message and its usage.
            claude("m1", at: "2026-10-01T10:01:00.500Z", input: 2, cacheRead: 100, cacheWrite: 50, output: 7),
            claude("m2", at: "2026-10-01T10:30:00Z", input: 1, cacheRead: 10, cacheWrite: 0, output: 3),
            claude("m3", model: "<synthetic>", at: "2026-10-01T11:00:00Z", input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
        ]) + Data("not json \"usage\"\n".utf8)
        let records = ClaudeTranscriptUsage.records(data, session: "file")
        XCTAssertEqual(records.count, 1, "Same model/session/hour aggregates; zero-token synthetic messages are dropped")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.session, "s1")
        XCTAssertEqual(record.hour, ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        XCTAssertEqual([record.uncachedInput, record.cachedInput, record.cacheWrite, record.output], [3, 110, 50, 10])
        XCTAssertEqual(record.total, 173)
    }

    func testCodexUsesCumulativeDeltasAndCurrentModel() throws {
        let data = try lines([
            ["timestamp": "2026-10-01T09:00:00Z", "type": "session_meta", "payload": ["id": "rollout-1"]],
            ["timestamp": "2026-10-01T09:00:01Z", "type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
            codex("2026-10-01T09:00:02Z", input: 1_000, cached: 400, output: 50),
            codex("2026-10-01T09:00:03Z", input: 1_000, cached: 400, output: 50),
            ["timestamp": "2026-10-01T10:00:00Z", "type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            codex("2026-10-01T10:00:05Z", input: 3_000, cached: 2_000, output: 80),
            // A restarted counter falls back to the last turn's usage.
            codex("2026-10-01T10:10:00Z", input: 200, cached: 100, output: 5)
        ])
        let records = CodexRolloutUsage.records(data, session: "file")
        XCTAssertEqual(records.map(\.model), ["gpt-6.1-sol", "gpt-6-astra"])
        XCTAssertEqual(records.map(\.session), ["rollout-1", "rollout-1"])
        XCTAssertEqual([records[0].uncachedInput, records[0].cachedInput, records[0].output], [600, 400, 50])
        XCTAssertEqual([records[1].uncachedInput, records[1].cachedInput, records[1].output], [400 + 100, 1_600 + 100, 30 + 5])
    }

    func testLedgerReadsSourcesSkipsOldFilesAndRefreshesChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent("claude/projects/p"), codexDirectory = root.appendingPathComponent("codex/sessions/2026/10/01")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let now = Date(), stamp = ISO8601DateFormatter().string(from: now)
        let claudeFile = claudeDirectory.appendingPathComponent("s1.jsonl"), old = claudeDirectory.appendingPathComponent("old.jsonl")
        try lines([claude("m1", at: stamp, input: 1, cacheRead: 0, cacheWrite: 0, output: 1)]).write(to: claudeFile)
        try lines([claude("m0", at: stamp, input: 50, cacheRead: 0, cacheWrite: 0, output: 50)]).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: old.path)
        try lines([codex(stamp, input: 10, cached: 0, output: 2)]).write(to: codexDirectory.appendingPathComponent("rollout-a.jsonl"))
        try Data("ignored".utf8).write(to: codexDirectory.appendingPathComponent("notes.txt"))
        let ledger = UsageLedger(sources: UsageLedger.defaultSources(environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
                                                                                   "CODEX_HOME": root.appendingPathComponent("codex").path]))
        var records = await ledger.records(since: now.addingTimeInterval(-86_400))
        XCTAssertEqual(records.map(\.total).sorted(), [2, 12], "Files last modified before the range are skipped")
        try lines([claude("m1", at: stamp, input: 1, cacheRead: 0, cacheWrite: 0, output: 1),
                   claude("m2", at: stamp, input: 3, cacheRead: 0, cacheWrite: 0, output: 4)]).write(to: claudeFile)
        records = await ledger.records(since: now.addingTimeInterval(-86_400))
        XCTAssertEqual(records.filter { $0.provider == .claude }.map(\.total), [9])
    }

    func testSummaryFillsEmptyBucketsAndRanksProvidersAndModels() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let interval = DateInterval(start: start, end: start.addingTimeInterval(3 * 86_400 - 1))
        let records = [
            UsageRecord(provider: .codex, model: "gpt", session: "a", hour: start.addingTimeInterval(3_600), cachedInput: 60, uncachedInput: 20, output: 20),
            UsageRecord(provider: .codex, model: "gpt", session: "b", hour: start.addingTimeInterval(2 * 86_400), uncachedInput: 100),
            UsageRecord(provider: .claude, model: "opus", session: "c", hour: start.addingTimeInterval(86_400), cacheWrite: 25, output: 25),
            UsageRecord(provider: .claude, model: "opus", session: "d", hour: start.addingTimeInterval(-3_600), output: 1_000)
        ]
        let summary = UsageSummary(records: records, interval: interval, calendar: calendar)
        XCTAssertFalse(summary.hourly)
        XCTAssertEqual(summary.total, 250, "Records outside the range are excluded")
        XCTAssertEqual(summary.sessions, 3)
        XCTAssertEqual(summary.providers.map(\.id), [.codex, .claude])
        XCTAssertEqual([summary.cachedInput, summary.cacheWrite, summary.uncachedInput, summary.output], [60, 25, 120, 45])
        XCTAssertEqual(summary.series.filter { $0.provider == .claude }.map(\.tokens), [0, 50, 0])
        XCTAssertEqual(summary.models.map(\.title), ["gpt", "opus"])
        XCTAssertEqual(summary.models[0].share, 0.8, accuracy: 0.0001)
        XCTAssertEqual(summary.days.map(\.tokens), [100, 50, 100])
        let day = UsageSummary(records: records, interval: DateInterval(start: start, end: start.addingTimeInterval(86_400)), calendar: calendar)
        XCTAssertTrue(day.hourly)
        XCTAssertEqual(day.series.filter { $0.provider == .codex }.count, 25)
    }

    func testMergingPushedLimitsKeepsOtherWindows() {
        let first = AgentUsage(buckets: [.init(id: "claude", title: "Claude", windows: [.init(id: "five_hour", usedPercent: 10), .init(id: "seven_day", usedPercent: 20)])], fetchedAt: Date(timeIntervalSince1970: 1))
        let update = AgentUsage(buckets: [.init(id: "claude", title: "Claude", windows: [.init(id: "seven_day", usedPercent: 30)])], fetchedAt: Date(timeIntervalSince1970: 2))
        let merged = AgentUsage.merging(update, into: first)
        XCTAssertEqual(merged.buckets[0].windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(merged.buckets[0].windows.map(\.usedPercent), [10, 30])
        XCTAssertEqual(merged.fetchedAt, Date(timeIntervalSince1970: 2))
    }
}
