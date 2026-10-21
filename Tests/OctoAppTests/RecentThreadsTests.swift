import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class RecentThreadsTests: XCTestCase {
    private func fixture() -> (AppStore, WorkspaceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        var first = WorkspaceThread(title: "First", workingDirectory: root.path)
        first.messages = [.init(role: .user, text: "First prompt")]
        var second = WorkspaceThread(title: "Second", workingDirectory: root.path)
        second.messages = [.init(role: .user, text: "Second prompt")]
        let a = WorkspaceProject(name: "A", rootPath: root.path, threads: [first])
        var b = WorkspaceProject(name: "B", rootPath: root.path, threads: [second])
        b.isCollapsed = true
        store.archive = WorkspaceArchive(projects: [a, b], selectedProjectID: a.id, selectedThreadID: first.id)
        return (store, storage, root)
    }

    func testSectionDisclosurePersistsIndependentlyWithoutChangingNavigation() throws {
        let (store, storage, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let selected = store.thread!.id
        store.drafts[selected] = "Keep this draft"
        store.toggleProjectsSection()
        XCTAssertEqual(store.archive.projectsSectionCollapsed, true)
        XCTAssertNotEqual(store.archive.recentSectionCollapsed, true)
        store.toggleRecentSection()
        store.toggleProjectsSection()
        XCTAssertEqual(store.thread?.id, selected)
        XCTAssertEqual(store.drafts[selected], "Keep this draft")
        XCTAssertTrue(store.archive.projects[1].isCollapsed, "Section disclosure leaves each project's disclosure alone")
        store.saveNow()
        let saved = try storage.load()
        XCTAssertEqual(saved.projectsSectionCollapsed, false)
        XCTAssertEqual(saved.recentSectionCollapsed, true)
        XCTAssertEqual(saved.selectedThreadID, selected)
    }

    func testLegacyArchiveLeavesBothSectionsExpanded() throws {
        let (store, _, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let data = try JSONEncoder().encode(store.archive)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["projectsSectionCollapsed"])
        XCTAssertNil(json["recentSectionCollapsed"])
        let decoded = try JSONDecoder().decode(WorkspaceArchive.self, from: data)
        XCTAssertNotEqual(decoded.projectsSectionCollapsed, true)
        XCTAssertNotEqual(decoded.recentSectionCollapsed, true)
    }

    func testRecentOrderSpansProjectsLimitsResultsAndExcludesDrafts() {
        var threads = (0..<10).map { index -> WorkspaceThread in
            var thread = WorkspaceThread(title: "Thread \(index)", workingDirectory: "/tmp")
            thread.createdAt = Date(timeIntervalSince1970: 0)
            var message = ChatMessage(role: .user, text: "Prompt")
            message.createdAt = Date(timeIntervalSince1970: Double(index + 1))
            thread.messages = [message]
            return thread
        }
        threads[0].isPinned = true
        threads[1].lastVisitedAt = Date(timeIntervalSince1970: 30)
        threads[2].lastActivityAt = Date(timeIntervalSince1970: 40)
        threads[3].lastDraftedAt = Date(timeIntervalSince1970: 35)
        threads.append(WorkspaceThread(workingDirectory: "/tmp"))
        let archive = WorkspaceArchive(projects: [
            .init(name: "A", rootPath: "/tmp", threads: Array(threads.prefix(5))),
            .init(name: "B", rootPath: "/tmp", threads: Array(threads.dropFirst(5)))
        ])
        XCTAssertEqual(archive.recentThreads.count, 8)
        // Activity and a started draft order Recent; a visit alone (Thread 1) does not.
        XCTAssertEqual(archive.recentThreads.prefix(3).map(\.thread.title), ["Thread 2", "Thread 3", "Thread 9"])
        XCTAssertEqual(threads[3].activityAt, Date(timeIntervalSince1970: 4), "A draft leaves the row's message time alone")
        XCTAssertFalse(archive.recentThreads.contains { $0.id == threads[0].id })
        XCTAssertFalse(archive.recentThreads.contains { $0.id == threads.last!.id })
        XCTAssertEqual(archive.recentThreads[2].project.name, "B")
    }

    func testSelectingLeavesRecentOrderAndStartingADraftMovesItsThreadUp() {
        let (store, _, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let older = store.archive.projects[0].threads[0]
        let before = store.archive.recentThreads.map(\.id)
        XCTAssertEqual(before.last, older.id)
        store.selectThread(store.archive.projects[1].threads[0], project: store.archive.projects[1])
        store.selectThread(older, project: store.archive.projects[0])
        XCTAssertEqual(store.archive.recentThreads.map(\.id), before, "Clicking a thread does not reorder Recent")
        store.drafts[older.id] = "  "
        XCTAssertEqual(store.archive.recentThreads.map(\.id), before, "Whitespace is not a draft")
        store.drafts[older.id] = "Follow up"
        XCTAssertEqual(store.archive.recentThreads.first?.id, older.id)
        let drafted = store.thread?.lastDraftedAt
        XCTAssertNotNil(drafted)
        store.drafts[older.id] = "Follow up, more"
        XCTAssertEqual(store.thread?.lastDraftedAt, drafted, "Only starting a draft counts")
    }

    func testUnreadCompletionPersistsUntilReadAndDuplicateFinishDoesNotRestoreIt() throws {
        let (store, storage, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let project = store.archive.projects[1], id = project.threads[0].id
        store.beginWork(id)
        store.receive(.textDelta("Completed answer"), threadID: id)
        store.receive(.finished, threadID: id)
        XCTAssertTrue(store.archive.projects[1].threads[0].hasUnreadCompletion)
        XCTAssertEqual(store.archive.recentThreads.first?.id, id)
        store.markThreadRead(id)
        XCTAssertTrue(store.archive.projects[1].threads[0].hasUnreadCompletion, "An unrelated selected chat cannot acknowledge this one")
        store.saveNow()
        let reloaded = AppStore(storage: storage)
        XCTAssertTrue(reloaded.archive.projects[1].threads[0].hasUnreadCompletion)
        reloaded.shutdown()
        store.selectThread(project.threads[0], project: project)
        XCTAssertTrue(store.thread!.hasUnreadCompletion, "Selection alone does not prove the chat is visible")
        store.showingTerminal = true
        store.markThreadRead(id)
        XCTAssertTrue(store.thread!.hasUnreadCompletion)
        store.showingTerminal = false
        store.markThreadRead(id)
        XCTAssertFalse(store.thread!.hasUnreadCompletion)
        store.receive(.finished, threadID: id)
        XCTAssertFalse(store.thread!.hasUnreadCompletion)
        store.saveNow()
        XCTAssertFalse(try storage.load().projects[1].threads[0].hasUnreadCompletion)
    }

    func testStoppedFailedAndInterruptedWorkDoNotCreateUnreadSuccess() {
        let (store, _, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = store.thread!.id
        store.beginWork(id); store.stop(id); store.receive(.finished, threadID: id)
        XCTAssertFalse(store.thread!.hasUnreadCompletion)
        store.beginWork(id); store.receive(.failed("Offline failure"), threadID: id)
        store.receive(.finished, threadID: id)
        XCTAssertFalse(store.thread!.hasUnreadCompletion)
        store.beginWork(id); store.shutdown()
        XCTAssertFalse(store.thread!.hasUnreadCompletion)
    }

    func testLegacyArchivesDefaultToReadAndNewMetadataRoundTrips() throws {
        var thread = WorkspaceThread(workingDirectory: "/tmp")
        thread.lastVisitedAt = Date(timeIntervalSince1970: 10)
        thread.lastActivityAt = Date(timeIntervalSince1970: 20)
        thread.unreadCompletedAt = Date(timeIntervalSince1970: 20)
        thread.lastDraftedAt = Date(timeIntervalSince1970: 15)
        let data = try JSONEncoder().encode(thread)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceThread.self, from: data), thread)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["lastVisitedAt", "lastActivityAt", "lastDraftedAt", "unreadCompletedAt"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(WorkspaceThread.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.hasUnreadCompletion)
        XCTAssertNil(decoded.lastVisitedAt)
        XCTAssertNil(decoded.lastActivityAt)
    }

    func testRecentNavigationAndDeletionKeepOwnershipAndDrafts() {
        let (store, _, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let project = store.archive.projects[1], thread = project.threads[0]
        store.drafts[thread.id] = "Unsent draft"
        store.selectThread(thread, project: project)
        XCTAssertEqual(store.project?.id, project.id)
        XCTAssertEqual(store.archive.recentThreads.first?.id, thread.id)
        XCTAssertEqual(store.drafts[thread.id], "Unsent draft")
        XCTAssertTrue(store.project!.isCollapsed)
        store.deleteThread(thread.id, projectID: project.id)
        XCTAssertFalse(store.archive.recentThreads.contains { $0.id == thread.id })
        store.selectThread(thread, project: project)
        XCTAssertNil(store.thread, "A stale Recent action must not select a deleted conversation")
    }
}
