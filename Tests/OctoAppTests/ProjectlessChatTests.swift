import Foundation
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ProjectlessChatTests: XCTestCase {
    private func location() -> (URL, WorkspaceStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
    }

    func testFreshWorkspaceStartsInChatsAndPersistsWithoutRepository() throws {
        let (root, storage) = location()
        let store = AppStore(storage: storage, titleGenerator: { _, _, _ in nil })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let chat = try XCTUnwrap(store.thread), collection = try XCTUnwrap(store.archive.chats)
        XCTAssertEqual(collection.name, "Chats")
        XCTAssertTrue(collection.rootPath.isEmpty)
        XCTAssertTrue(store.archive.orderedProjects.isEmpty)
        XCTAssertEqual(store.project?.id, collection.id)
        XCTAssertFalse(store.isProjectChat)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chat.workingDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chat.workingDirectory + "/.git"))
        let permissions = try FileManager.default.attributesOfItem(atPath: chat.workingDirectory)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        store.renameThread(chat.id, title: "Weekend ideas")
        store.toggleThreadPin(chat.id)
        store.beginWork(chat.id)
        store.receive(.textDelta("A saved idea 🐙"), threadID: chat.id)
        store.receive(.finished, threadID: chat.id)
        store.saveNow()
        let reload = AppStore(storage: storage, titleGenerator: { _, _, _ in nil })
        defer { reload.shutdown() }
        XCTAssertEqual(reload.archive.projects.filter(\.isChatCollection).count, 1)
        XCTAssertEqual(reload.thread?.id, chat.id)
        XCTAssertEqual(reload.thread?.workingDirectory, chat.workingDirectory)
        XCTAssertEqual(reload.thread?.messages.last?.text, "A saved idea 🐙")
        XCTAssertEqual(reload.thread?.title, "Weekend ideas")
        XCTAssertEqual(reload.thread?.isPinned, true)
        XCTAssertEqual(reload.archive.recentThreads.first?.thread.id, chat.id)
    }

    func testMigrationPreservesSelectedProjectEvenWhenNamedChats() throws {
        let (root, storage) = location()
        let thread = WorkspaceThread(workingDirectory: root.path)
        let project = WorkspaceProject(name: "Chats", rootPath: root.path, threads: [thread])
        try storage.save(WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id))
        // A pre-feature archive lacks this key entirely.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL)) as? [String: Any])
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "isChatCollection"); json["projects"] = projects
        try JSONSerialization.data(withJSONObject: json).write(to: storage.fileURL)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.archive.orderedProjects, [project])
        XCTAssertEqual(store.thread, thread)
        XCTAssertNotEqual(store.archive.chats?.id, project.id)
        store.newChat()
        XCTAssertEqual(store.project?.isChatCollection, true)
        XCTAssertEqual(store.archive.orderedProjects, [project])
        XCTAssertEqual(store.archive.searchableThreads.map(\.id), [store.thread!.id, thread.id])
        store.selectThread(thread, project: project)
        XCTAssertEqual(store.thread?.id, thread.id)
        XCTAssertTrue(store.isProjectChat)
    }

    func testNewChatReusesDraftButStartedChatsHaveIndependentDirectories() throws {
        let (root, storage) = location()
        let store = AppStore(storage: storage, titleGenerator: { _, _, _ in nil })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(store.thread)
        store.drafts[first.id] = "An unsent idea"
        store.newChat()
        XCTAssertEqual(store.thread?.id, first.id)
        XCTAssertEqual(store.drafts[first.id], "An unsent idea")
        store.prepareThreadTitle(first, text: "An unsent idea")
        XCTAssertEqual(store.thread?.title, "An unsent idea")
        let p = try XCTUnwrap(store.archive.projects.firstIndex(where: \.isChatCollection))
        store.archive.projects[p].threads[0].messages = [.init(role: .user, text: "Started")]
        store.newChat()
        let second = try XCTUnwrap(store.thread)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNotEqual(second.workingDirectory, first.workingDirectory)
        XCTAssertEqual(store.archive.chats?.threads.count, 2)
        store.deleteThread(second.id, projectID: store.project!.id)
        XCTAssertEqual(store.thread?.id, first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.workingDirectory), "Deleting history must not silently delete agent-created files")
    }

    func testBuiltInCollectionCannotBeRemovedRenamedPinnedOrOpenTerminal() throws {
        let (root, storage) = location()
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let chats = try XCTUnwrap(store.archive.chats)
        store.renameProject(chats.id, name: "Other")
        store.toggleProjectPin(chats.id)
        store.removeProject(chats.id)
        store.openTerminal(chats)
        XCTAssertEqual(store.archive.chats?.name, "Chats")
        XCTAssertEqual(store.archive.chats?.isPinned, false)
        XCTAssertTrue(store.terminal.tabs.isEmpty)
        XCTAssertFalse(store.showingTerminal)
        store.deleteThread(store.thread!.id, projectID: chats.id)
        store.openChats()
        XCTAssertNotNil(store.thread)
        XCTAssertEqual(store.archive.chats?.threads.count, 1)
    }

    func testChatDirectoryRejectsSymlinkAndBroadPermissions() throws {
        let (root, storage) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        try storage.save(WorkspaceArchive())
        let outside = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("ChatWorkspaces")
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: outside)
        XCTAssertThrowsError(try storage.prepareChatDirectory(UUID()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try storage.prepareChatDirectory(UUID()))
    }

    func testUnreadableArchiveDoesNotCreateOrOverwriteChats() throws {
        let (root, storage) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let original = Data("not an archive".utf8)
        try original.write(to: storage.fileURL)
        let store = AppStore(storage: storage)
        store.newChat(); store.shutdown()
        XCTAssertNil(store.archive.chats)
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ChatWorkspaces").path))
    }
}
