import XCTest
@testable import OctoCore

final class ReviewTests: XCTestCase {
    func snapshot(_ lines: [DiffLine]) -> ReviewSnapshot {
        ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "code.swift", scope: .working, baseRevision: "abc", lines: lines)
    }
    func testUnicodeSelectionPreservesSourceAndExcludesGutters() {
        let document = ReviewDocument(snapshot: snapshot([
            .init(id: 0, kind: .header, text: "@@ -1 +1 @@"),
            .init(id: 1, kind: .deletion, text: "let old = 1", oldLine: 1),
            .init(id: 2, kind: .addition, text: "let octo = \"🐙 café\"", newLine: 1)
        ]))
        let range = (document.text as NSString).range(of: "🐙 café")
        let attachment = document.attachment(for: range)
        XCTAssertEqual(attachment?.text, "🐙 café")
        XCTAssertEqual(attachment?.newLines, 1...1)
        XCTAssertNil(attachment?.oldLines)
        let all = document.attachment(for: NSRange(location: 0, length: (document.text as NSString).length))
        XCTAssertEqual(all?.text, "let old = 1\nlet octo = \"🐙 café\"")
        XCTAssertEqual(all?.oldLines, 1...1)
        XCTAssertEqual(all?.snapshotID, document.snapshot.id)
        XCTAssertNil(document.attachment(for: NSRange(location: 0, length: 5)))
        XCTAssertNil(document.attachment(for: NSRange(location: NSNotFound, length: 0)))
    }
    func testSnapshotChangesWithContentAndScope() {
        let a = snapshot([.init(id: 0, kind: .addition, text: "a", newLine: 1)])
        let b = snapshot([.init(id: 0, kind: .addition, text: "b", newLine: 1)])
        XCTAssertNotEqual(a.id, b.id)
        let same = snapshot(a.lines)
        XCTAssertEqual(a.id, same.id)
        let file = ReviewSnapshot(projectID: a.projectID, workingDirectory: a.workingDirectory, path: a.path, scope: .file, baseRevision: a.baseRevision, lines: a.lines)
        XCTAssertNotEqual(file.id, a.id)
    }
    func testHoverAttachmentCapturesSourceLinesAndRejectsHeaders() throws {
        let doc = ReviewDocument(snapshot: snapshot([
            .init(id: 0, kind: .header, text: "@@ -4,1 +4,2 @@"),
            .init(id: 1, kind: .deletion, text: "old 🐙", oldLine: 4),
            .init(id: 2, kind: .addition, text: "new café", newLine: 4),
            .init(id: 3, kind: .addition, text: "", newLine: 5)
        ]))
        let empty = NSRange(location: NSNotFound, length: 0)
        XCTAssertNil(doc.attachmentRange(forLineAtUTF16Offset: 0, selection: empty))
        XCTAssertNil(doc.attachmentRange(forLineAtUTF16Offset: -1, selection: empty))
        XCTAssertNil(doc.attachmentRange(forLineAtUTF16Offset: (doc.text as NSString).length, selection: empty))
        for index in 1...3 {
            // Gutter, source text, and newline all resolve to the same source line.
            let segment = doc.segments[index]
            for offset in [segment.displayRange.location, segment.contentRange.location, NSMaxRange(segment.displayRange) - 1] {
                let range = try XCTUnwrap(doc.attachmentRange(forLineAtUTF16Offset: offset, selection: empty))
                let attachment = try XCTUnwrap(doc.attachment(for: range))
                XCTAssertEqual(attachment.text, segment.line.text)
                XCTAssertEqual(attachment.oldLines, segment.line.oldLine.map { $0...$0 })
                XCTAssertEqual(attachment.newLines, segment.line.newLine.map { $0...$0 })
                XCTAssertEqual(attachment.path, doc.snapshot.path)
                XCTAssertEqual(attachment.workingDirectory, doc.snapshot.workingDirectory)
                XCTAssertEqual(attachment.snapshotID, doc.snapshot.id)
            }
        }
    }
    func testHoverAttachmentUsesIntersectingSelectionOnly() throws {
        let doc = ReviewDocument(snapshot: snapshot([
            .init(id: 0, kind: .context, text: "first 🐙", oldLine: 1, newLine: 1),
            .init(id: 1, kind: .context, text: "", oldLine: 2, newLine: 2),
            .init(id: 2, kind: .context, text: "third", oldLine: 3, newLine: 3)
        ]))
        let start = (doc.text as NSString).range(of: "🐙").location
        let selection = NSRange(location: start, length: doc.segments[2].displayRange.location - start)
        for index in [0, 1] {
            let range = try XCTUnwrap(doc.attachmentRange(forLineAtUTF16Offset: doc.segments[index].displayRange.location, selection: selection))
            XCTAssertEqual(range, selection)
            XCTAssertEqual(doc.attachment(for: range)?.text, "🐙\n")
            XCTAssertEqual(doc.attachment(for: range)?.newLines, 1...2)
        }
        let outside = try XCTUnwrap(doc.attachmentRange(forLineAtUTF16Offset: doc.segments[2].displayRange.location, selection: selection))
        XCTAssertEqual(doc.attachment(for: outside)?.text, "third")
        let gutter = NSRange(location: 0, length: 5)
        let line = try XCTUnwrap(doc.attachmentRange(forLineAtUTF16Offset: 0, selection: gutter))
        XCTAssertEqual(doc.attachment(for: line)?.text, "first 🐙")
    }
    func testMultilineSelectionKeepsEmptySourceLines() {
        let doc = ReviewDocument(snapshot: snapshot([
            .init(id: 0, kind: .context, text: "first", newLine: 1),
            .init(id: 1, kind: .context, text: "", newLine: 2),
            .init(id: 2, kind: .context, text: "third", newLine: 3)
        ]))
        XCTAssertEqual(doc.attachment(for: NSRange(location: 0, length: (doc.text as NSString).length))?.text, "first\n\nthird")
    }
    func testSidebarPreferencesRoundTripAndLegacyDefaults() throws {
        var project = WorkspaceProject(name: "octo", rootPath: "/tmp/octo", threads: [.init(workingDirectory: "/tmp/octo")])
        project.threads[0].agentSettings = AgentSettings(model: "fixture-model", reasoningEffort: "high")
        project.isPinned = true; project.isCollapsed = true; project.threads[0].isPinned = true
        let data = try JSONEncoder().encode(WorkspaceArchive(projects: [project]))
        let decoded = try JSONDecoder().decode(WorkspaceArchive.self, from: data)
        XCTAssertEqual(decoded.projects, [project])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "isPinned"); projects[0].removeValue(forKey: "isCollapsed")
        var threads = try XCTUnwrap(projects[0]["threads"] as? [[String: Any]])
        threads[0].removeValue(forKey: "agentSettings"); threads[0].removeValue(forKey: "isPinned"); projects[0]["threads"] = threads; json["projects"] = projects
        let legacy = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.projects[0].threads[0].agentSettings, AgentSettings())
        XCTAssertFalse(legacy.projects[0].isPinned)
        XCTAssertFalse(legacy.projects[0].isCollapsed)
        XCTAssertFalse(legacy.projects[0].threads[0].isPinned)
        XCTAssertEqual(legacy.projects[0].threads[0].id, project.threads[0].id)
    }
    func testPinnedOrderingAndRemovalSelection() {
        var first = WorkspaceProject(name: "first", rootPath: "/tmp/first", threads: (0..<3).map { WorkspaceThread(title: "Thread \($0)", workingDirectory: "/tmp/first") })
        first.threads[1].isPinned = true
        var second = WorkspaceProject(name: "second", rootPath: "/tmp/second")
        second.isPinned = true
        var archive = WorkspaceArchive(projects: [first, second], selectedProjectID: first.id, selectedThreadID: first.threads[0].id)
        XCTAssertEqual(archive.orderedProjects.map(\.id), [second.id, first.id])
        XCTAssertEqual(first.orderedThreads.map(\.id), [first.threads[1].id, first.threads[2].id, first.threads[0].id])
        archive.removeThread(first.threads[2].id, projectID: first.id)
        XCTAssertEqual(archive.selectedThreadID, first.threads[0].id)
        archive.removeThread(first.threads[0].id, projectID: first.id)
        XCTAssertEqual(archive.selectedThreadID, first.threads[1].id)
        archive.removeProject(first.id)
        XCTAssertEqual(archive.selectedProjectID, second.id)
        XCTAssertNil(archive.selectedThreadID)
        archive.removeProject(second.id)
        XCTAssertNil(archive.selectedProjectID)
    }
    func testNewestFirstThreadsPreserveArchiveOrderAndPinsAcrossReload() throws {
        for isChatCollection in [false, true] {
            var project = WorkspaceProject(name: "Conversations", rootPath: "/tmp", threads:
                (0..<4).map { WorkspaceThread(title: "Thread \($0)", workingDirectory: "/tmp") })
            project.isChatCollection = isChatCollection
            project.threads[0].isPinned = true
            project.threads[2].isPinned = true
            // Activity on an older thread must not move it within its pin group.
            project.threads[1].lastActivityAt = Date.distantFuture
            let originalIDs = project.threads.map(\.id)
            let data = try JSONEncoder().encode(WorkspaceArchive(projects: [project]))
            var archive = try JSONDecoder().decode(WorkspaceArchive.self, from: data)
            XCTAssertEqual(archive.projects[0].threads.map(\.id), originalIDs)
            XCTAssertEqual(archive.projects[0].orderedThreads.map(\.title), ["Thread 2", "Thread 0", "Thread 3", "Thread 1"])
            archive.projects[0].threads[0].isPinned = false
            archive.projects[0].threads[2].isPinned = false
            XCTAssertEqual(archive.projects[0].orderedThreads.map(\.title), ["Thread 3", "Thread 2", "Thread 1", "Thread 0"])
            let newest = WorkspaceThread(title: "Newest", workingDirectory: "/tmp")
            archive.projects[0].threads.append(newest)
            XCTAssertEqual(archive.projects[0].orderedThreads.first?.id, newest.id)
            archive.selectedThreadID = newest.id
            archive.removeThread(newest.id, projectID: project.id)
            XCTAssertEqual(archive.selectedThreadID, originalIDs[3])
        }
    }

    func testImageMessageRoundTripAndLegacyDecoding() throws {
        let image = ImageAttachment(pngData: Data([1, 2, 3]))
        let message = ChatMessage(role: .user, text: "Look at this", images: [image])
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data), message)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "images")
        XCTAssertTrue(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).images.isEmpty)
    }

    func testStoreRoundTripAndPreservesUnsupportedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let project = WorkspaceProject(name: "octo", rootPath: "/tmp/octo", threads: [.init(workingDirectory: "/tmp/octo")])
        var archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id)
        try store.save(archive)
        XCTAssertEqual(try store.load().projects, [project])
        archive.schemaVersion = 999
        try store.save(archive)
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }
}
