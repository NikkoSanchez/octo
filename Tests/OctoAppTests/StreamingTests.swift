import Combine
import XCTest
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor final class StreamingTests: XCTestCase {
    private func fixture() -> (AppStore, WorkspaceStore, URL, UUID, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        var a = WorkspaceThread(workingDirectory: root.path), b = WorkspaceThread(workingDirectory: root.path)
        a.messages = [.init(role: .user, text: "One")]; b.messages = [.init(role: .user, text: "Two")]
        store.archive = WorkspaceArchive(projects: [.init(name: "Concurrent", rootPath: root.path, threads: [a, b])])
        store.beginWork(a.id); store.beginWork(b.id)
        return (store, storage, root, a.id, b.id)
    }
    func testConcurrentFragmentsPublishOnceWithoutLosingText() {
        let (store, _, root, a, b) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var publications = 0
        let subscription = store.$archive.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<1_000 {
            store.receive(.textDelta("🐙"), threadID: a)
            store.receive(.textDelta("b"), threadID: b)
        }
        XCTAssertEqual(publications, 0)
        store.flushStreamText()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.archive.projects[0].threads[0].messages.last?.text, String(repeating: "🐙", count: 1_000))
        XCTAssertEqual(store.archive.projects[0].threads[1].messages.last?.text, String(repeating: "b", count: 1_000))
    }
    func testBoundariesKeepRolesToolActivityAndCompletionInOrder() {
        let (store, _, root, a, _) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.receive(.reasoningDelta("Thinking"), threadID: a)
        store.receive(.textDelta("Answer"), threadID: a)
        let tool = ToolActivity(id: "tool", server: "fixture", tool: "test", state: .running)
        store.receive(.toolActivity(tool), threadID: a)
        store.receive(.activityDelta("Commentary"), threadID: a)
        store.receive(.textDelta("Final"), threadID: a)
        store.receive(.finished, threadID: a)
        let messages = store.archive.projects[0].threads[0].messages
        var interruptedTool = tool; interruptedTool.state = .interrupted
        XCTAssertEqual(messages.map(\.text), ["One", "Thinking", "Answer", interruptedTool.text, "Commentary", "Final"])
        XCTAssertEqual(messages[3].toolActivity, interruptedTool)
        XCTAssertNil(messages[4].toolActivity)
        XCTAssertNotNil(messages.last?.completedAt)
        XCTAssertEqual(messages[0].work?.outcome, .completed)
        store.receive(.textDelta("Late"), threadID: a)
        store.flushStreamText()
        XCTAssertEqual(store.archive.projects[0].threads[0].messages.last?.text, "Final")
    }
    func testStopFailureAndShutdownPersistPendingText() throws {
        let (store, storage, root, a, b) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.receive(.textDelta("Before stop"), threadID: a)
        store.stop(a)
        store.receive(.textDelta("After stop"), threadID: a)
        store.receive(.finished, threadID: a)
        store.receive(.textDelta("Before error"), threadID: b)
        store.receive(.failed("Disconnected"), threadID: b)
        store.beginWork(b)
        store.receive(.textDelta("Before shutdown"), threadID: b)
        store.shutdown()
        let threads = try storage.load().projects[0].threads
        XCTAssertEqual(threads[0].messages.last?.text, "Before stop")
        XCTAssertEqual(threads[0].messages[0].work?.outcome, .stopped)
        XCTAssertEqual(threads[1].messages.map(\.text), ["Two", "Before error", "Disconnected", "Before shutdown"])
    }
    func testTimerAndBufferLimitFlushWithoutProtocolBoundary() async throws {
        let (store, storage, root, a, b) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.receive(.textDelta("Timer"), threadID: a)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.archive.projects[0].threads[0].messages.last?.text, "Timer")
        let large = String(repeating: "x", count: 65_536)
        store.receive(.textDelta(large), threadID: b)
        XCTAssertEqual(store.archive.projects[0].threads[1].messages.last?.text, large)
        store.receive(.textDelta(" saved"), threadID: a)
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].messages.last?.text, "Timer saved")
    }
}
