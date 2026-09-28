import XCTest
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor final class ConversationUsageRoutingTests: XCTestCase {
    func testSnapshotsReplacePersistAndStayWithOwningThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        defer { store.shutdown() }
        let first = WorkspaceThread(workingDirectory: root.path), second = WorkspaceThread(harness: .claude, workingDirectory: root.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [first, second])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: second.id)
        let initial = ConversationUsage(latest: .init(total: 180_000), session: .init(total: 800_000), contextWindow: 200_000)
        store.handle(.conversationUsage(initial), threadID: first.id)
        store.handle(.conversationUsage(initial), threadID: first.id)
        XCTAssertNil(store.thread?.conversationUsage)
        XCTAssertEqual(store.archive.projects[0].threads[0].conversationUsage, initial)
        // Provider reset/recompaction can reduce both counters. Replacement must preserve that.
        let reduced = ConversationUsage(latest: .init(total: 30_000), session: .init(total: 40_000), contextWindow: nil)
        store.handle(.conversationUsage(reduced), threadID: first.id)
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].conversationUsage, reduced)
        store.changeHarness(.codex)
        XCTAssertNil(store.thread?.conversationUsage, "Switching an unused provider draft must not inherit another thread's counts")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        legacy.removeValue(forKey: "conversationUsage"); legacy.removeValue(forKey: "lastCompaction")
        let decoded = try JSONDecoder().decode(WorkspaceThread.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.conversationUsage)
        XCTAssertNil(decoded.lastCompaction)
    }

    func testCompactionLifecycleStopFailureRelaunchAndCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        defer { store.shutdown() }
        var thread = WorkspaceThread(workingDirectory: root.path)
        thread.messages = [.init(role: .user, text: "Fixture")]
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        var compaction = ContextCompaction(id: "one", state: .compacting)
        store.handle(.compaction(compaction), threadID: thread.id)
        XCTAssertNil(store.thread?.lastCompaction, "An idle thread cannot enter compaction")
        store.beginWork(thread.id)
        store.handle(.compaction(compaction), threadID: thread.id)
        store.handle(.compaction(compaction), threadID: thread.id)
        store.stop(thread.id)
        XCTAssertEqual(store.thread?.lastCompaction?.state, .interrupted)
        compaction.state = .completed
        store.handle(.compaction(compaction), threadID: thread.id)
        XCTAssertEqual(store.thread?.lastCompaction?.state, .interrupted, "Late completion after stop must not restore success")
        store.handle(.finished, threadID: thread.id)
        store.beginWork(thread.id)
        compaction = ContextCompaction(id: "two", state: .compacting)
        store.handle(.compaction(compaction), threadID: thread.id)
        store.handle(.failed("Disconnected"), threadID: thread.id)
        XCTAssertEqual(store.thread?.lastCompaction?.state, .interrupted)
        store.beginWork(thread.id)
        compaction = ContextCompaction(id: "three", state: .compacting)
        store.handle(.compaction(compaction), threadID: thread.id)
        compaction.state = .completed; compaction.endedAt = Date()
        store.handle(.compaction(compaction), threadID: thread.id)
        store.handle(.finished, threadID: thread.id)
        XCTAssertEqual(store.thread?.lastCompaction, compaction)
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].lastCompaction, compaction)
        var archive = try storage.load()
        archive.projects[0].threads[0].lastCompaction?.state = .compacting
        try storage.save(archive)
        let restarted = AppStore(storage: storage)
        XCTAssertEqual(restarted.thread?.lastCompaction?.state, .interrupted)
        restarted.shutdown()
    }
}
