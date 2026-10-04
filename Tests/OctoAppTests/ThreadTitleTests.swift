import XCTest
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor final class ThreadTitleTests: XCTestCase {
    private func fixture(generator: @escaping AppStore.TitleGenerator) throws -> (AppStore, PrivateTemporaryDirectory, WorkspaceStore) {
        let root = try PrivateTemporaryDirectory()
        let storage = WorkspaceStore(fileURL: root.url.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage, titleGenerator: generator)
        let thread = WorkspaceThread(workingDirectory: root.url.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.url.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        return (store, root, storage)
    }
    func testHoverAgeUsesCompactUnitsAndClampsFutureDates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for (seconds, label) in [(0.0, "now"), (-100, "now"), (59, "now"), (60, "1m"), (2_400, "40m"),
                                 (3_600, "1h"), (86_400, "1d"), (259_200, "3d"), (31_536_000, "1y")] {
            XCTAssertEqual(ThreadHoverDetails.age(since: now.addingTimeInterval(-seconds), now: now), label)
        }
    }
    func testHoverDateIgnoresVisitsAndUsesLegacyMessageDate() {
        var thread = WorkspaceThread(workingDirectory: "/tmp")
        thread.createdAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ThreadHoverDetails.activityDate(thread), thread.createdAt)
        var message = ChatMessage(role: .assistant, text: "Reply")
        message.createdAt = Date(timeIntervalSince1970: 200)
        message.completedAt = Date(timeIntervalSince1970: 300)
        thread.messages = [message]
        thread.lastVisitedAt = Date(timeIntervalSince1970: 900)
        XCTAssertEqual(ThreadHoverDetails.activityDate(thread), message.completedAt)
        thread.lastActivityAt = Date(timeIntervalSince1970: 400)
        XCTAssertEqual(ThreadHoverDetails.activityDate(thread), thread.lastActivityAt)
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }

    func testSummaryUsesFirstTextAndPersistsWithoutChangingConversationSettings() async throws {
        var input = ""
        let (store, root, storage) = try fixture { provider, text, _ in
            XCTAssertEqual(provider, .codex); input = text; return "Improve sidebar navigation"
        }
        defer { store.shutdown(); withExtendedLifetime(root) {} }
        store.archive.projects[0].threads[0].agentSettings = AgentSettings(model: "chat-model", reasoningEffort: "high")
        let thread = store.thread!
        store.prepareThreadTitle(thread, text: String(repeating: "a", count: 5_000))
        XCTAssertEqual(store.thread?.title, String(repeating: "a", count: 52))
        await settle()
        XCTAssertEqual(input.count, 4_000)
        XCTAssertEqual(store.thread?.title, "Improve sidebar navigation")
        XCTAssertEqual(store.thread?.agentSettings, thread.agentSettings)
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].title, "Improve sidebar navigation")
    }

    func testNoConfigEmptyTextFailureAndExistingChatKeepFallback() async throws {
        var calls = 0
        let (store, root, _) = try fixture { _, _, _ in calls += 1; throw ProcessFailure.timedOut }
        defer { store.shutdown(); withExtendedLifetime(root) {} }
        store.archive.projects[0].threads[0].harness = .claude
        store.prepareThreadTitle(store.thread!, text: "First message")
        await settle(); XCTAssertEqual(calls, 0); XCTAssertEqual(store.thread?.title, "First message")
        store.archive.projects[0].threads[0] = WorkspaceThread(workingDirectory: root.url.path)
        store.archive.selectedThreadID = store.archive.projects[0].threads[0].id
        store.prepareThreadTitle(store.thread!, text: "")
        await settle(); XCTAssertEqual(calls, 0); XCTAssertEqual(store.thread?.title, "Screenshot discussion")
        store.archive.projects[0].threads[0].title = "New thread"
        store.prepareThreadTitle(store.thread!, text: "Failed generation fallback")
        await settle(); XCTAssertEqual(calls, 1); XCTAssertEqual(store.thread?.title, "Failed generation fallback")
        store.archive.projects[0].threads[0].title = "New thread"
        store.archive.projects[0].threads[0].messages = [.init(role: .user, text: "Existing")]
        store.prepareThreadTitle(store.thread!, text: "Don't rename history")
        await settle(); XCTAssertEqual(calls, 1)
    }

    func testLateResultsCannotOverwriteManualRenameOrRecreateDeletedThreads() async throws {
        var complete: CheckedContinuation<String?, Error>?
        let (store, root, storage) = try fixture { _, _, _ in try await withCheckedThrowingContinuation { complete = $0 } }
        defer { store.shutdown(); withExtendedLifetime(root) {} }
        let id = store.thread!.id
        store.prepareThreadTitle(store.thread!, text: "Original fallback")
        await settle()
        store.renameThread(id, title: "Original fallback") // Even renaming to the same text is authoritative.
        complete?.resume(returning: "Late automatic title"); complete = nil
        await settle()
        XCTAssertEqual(store.thread?.title, "Original fallback")
        XCTAssertTrue(store.thread!.isTitleManuallySet)
        store.saveNow(); XCTAssertTrue(try storage.load().projects[0].threads[0].isTitleManuallySet)
        store.archive.projects[0].threads[0] = WorkspaceThread(workingDirectory: root.url.path)
        store.archive.selectedThreadID = store.archive.projects[0].threads[0].id
        store.prepareThreadTitle(store.thread!, text: "Delete me")
        await settle()
        store.deleteThread(store.thread!.id, projectID: store.project!.id)
        complete?.resume(returning: "Must not reappear"); complete = nil
        await settle(); XCTAssertTrue(store.archive.projects[0].threads.isEmpty)
    }

    func testManuallyNamedDraftAndLegacyDecoding() async throws {
        let (store, root, _) = try fixture { _, _, _ in XCTFail("Manual draft must not request a title"); return nil }
        defer { store.shutdown(); withExtendedLifetime(root) {} }
        store.renameThread(store.thread!.id, title: "New thread")
        store.prepareThreadTitle(store.thread!, text: "Do not replace manual name")
        await settle(); XCTAssertEqual(store.thread?.title, "New thread")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.thread!)) as? [String: Any])
        object.removeValue(forKey: "isTitleManuallySet")
        let legacy = try JSONDecoder().decode(WorkspaceThread.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.isTitleManuallySet)
        XCTAssertEqual(legacy.title, "New thread")
    }

    func testShutdownRejectsLateTitle() async throws {
        var complete: CheckedContinuation<String?, Error>?
        let (store, root, _) = try fixture { _, _, _ in try await withCheckedThrowingContinuation { complete = $0 } }
        defer { withExtendedLifetime(root) {} }
        store.prepareThreadTitle(store.thread!, text: "Keep fallback")
        await settle(); store.shutdown()
        complete?.resume(returning: "Too late"); await settle()
        XCTAssertEqual(store.thread?.title, "Keep fallback")
    }
}
