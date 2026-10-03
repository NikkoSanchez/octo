import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class FileActionTests: XCTestCase {
    private func fixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octo-file-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = try XCTUnwrap(Executables.find("git"))
        let result = try await ProcessRunner.run(git, arguments: ["init", "--quiet"], directory: root)
        XCTAssertEqual(result.status, 0)
        return root
    }
    private func context(_ root: URL, path: String = "file") -> ReviewSnapshot {
        ReviewSnapshot(projectID: UUID(), workingDirectory: root.path, path: path, scope: .file, baseRevision: "HEAD", lines: [])
    }
    func testCreateClosesDialogAndOpensInlineEditor() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), review = ReviewModel()
        review.browsingFiles = true
        await review.refresh(projectID: id, root: root.path)
        let model = FileActionModel(FileAction(kind: .create, projectID: id, root: root.path, path: "new.swift"))
        let created = await model.perform { await review.fileDidChange($0, deleted: false, projectID: id, root: root.path) }
        XCTAssertTrue(created)
        XCTAssertEqual(review.selectedPath, "new.swift")
        XCTAssertEqual(review.tree.map(\.id), ["new.swift"])
        let editor = try XCTUnwrap(review.editor)
        XCTAssertEqual(editor.text, "")
        editor.text = "let café = \"🐙\"\n"
        await editor.save()
        XCTAssertFalse(editor.isDirty)
        XCTAssertTrue(review.files.contains { $0.path == "new.swift" })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.swift"), encoding: .utf8), editor.text)
        editor.text = "second\n"
        await editor.save()
        XCTAssertFalse(editor.isDirty, "Repeated saves use the newly written baseline")
        XCTAssertNil(editor.error)
    }
    func testNavigationRetainsDirtyBufferAndCheckoutIdentity() async throws {
        let root = try await fixture(), other = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        for directory in [root, other] { try "original".write(to: directory.appendingPathComponent("file"), atomically: true, encoding: .utf8) }
        let editors = FileEditorWorkspace(), review = ReviewModel(editors: editors), id = UUID()
        review.browsingFiles = true
        await review.refresh(projectID: id, root: root.path)
        await review.selectPath("file", projectID: id, root: root.path)
        let first = try XCTUnwrap(review.editor)
        first.suspend(); first.text = "draft"
        await review.refresh(projectID: id, root: other.path)
        await review.selectPath("file", projectID: id, root: other.path)
        XCTAssertFalse(review.editor === first)
        XCTAssertEqual(review.editor?.text, "original")
        await review.refresh(projectID: id, root: root.path)
        await review.selectPath("file", projectID: id, root: root.path)
        XCTAssertTrue(review.editor === first)
        XCTAssertEqual(review.editor?.text, "draft")
        XCTAssertTrue(editors.hasUnsavedChanges)
        first.resume(); await first.save()
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("file"), encoding: .utf8), "original")
        XCTAssertFalse(editors.hasUnsavedChanges)
    }
    func testCanonicallyEquivalentUnicodeStillSavesChangedBytes() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try "e\u{301}".write(to: url, atomically: true, encoding: .utf8)
        let editor = FileEditorSession(context: context(root))
        await editor.load(); editor.text = "é"
        XCTAssertTrue(editor.isDirty)
        await editor.save()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), Data("é".utf8))
    }
    func testExternalDeletionKeepsDirtyFileReachableInTree() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let review = ReviewModel(), id = UUID(); review.browsingFiles = true
        await review.refresh(projectID: id, root: root.path)
        await review.selectPath("file", projectID: id, root: root.path)
        let editor = try XCTUnwrap(review.editor)
        editor.suspend(); editor.text = "retained draft"
        try FileManager.default.removeItem(at: url)
        await review.refresh(projectID: id, root: root.path)
        XCTAssertEqual(review.tree.map(\.id), ["file"])
        XCTAssertTrue(review.editor === editor)
        XCTAssertEqual(review.editor?.text, "retained draft")
        XCTAssertEqual(review.snapshot?.path, "file")
    }
    func testConflictRetainsDraftUntilExplicitReload() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try "first".write(to: url, atomically: true, encoding: .utf8)
        let model = FileEditorSession(context: context(root))
        await model.load(); model.text = "my edits"
        try "external".write(to: url, atomically: true, encoding: .utf8)
        var refreshed = false
        model.didSave = { refreshed = true }
        await model.save()
        XCTAssertFalse(refreshed); XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.error); XCTAssertEqual(model.text, "my edits"); XCTAssertTrue(model.isDirty)
        await model.load()
        XCTAssertEqual(model.text, "my edits")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        await model.load(discardChanges: true)
        XCTAssertEqual(model.text, "external"); XCTAssertFalse(model.isDirty); XCTAssertNil(model.error)
    }
    func testAutosavePersistsLatestTextAndSuspensionCancelsPendingWrites() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try "initial".write(to: url, atomically: true, encoding: .utf8)
        let model = FileEditorSession(context: context(root), autosaveDelay: 10_000_000)
        await model.load()
        model.text = "superseded"; model.text = "latest 🐙\r\n"
        for _ in 0..<100 where model.isDirty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isDirty); XCTAssertNil(model.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest 🐙\r\n")
        model.text = "pending deletion"; model.suspend()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest 🐙\r\n")
        model.resume(); await model.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "pending deletion")
    }
    func testDeleteClearsEditorAndOldCheckoutRefreshIsIgnored() async throws {
        let root = try await fixture(), other = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try "source".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try "other".write(to: other.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        let id = UUID(), review = ReviewModel(); review.browsingFiles = true
        await review.refresh(projectID: id, root: root.path)
        await review.selectPath("file", projectID: id, root: root.path)
        let editor = try XCTUnwrap(review.editor)
        editor.text = "pending"
        let removal = FileActionModel(FileAction(kind: .delete, projectID: id, root: root.path, path: "file"), editors: review.editors)
        await removal.load()
        let removed = await removal.perform { await review.fileDidChange($0, deleted: true, projectID: id, root: root.path) }
        XCTAssertTrue(removed); XCTAssertNil(review.selectedPath); XCTAssertNil(review.snapshot); XCTAssertNil(review.editor)
        XCTAssertFalse(review.editors.hasUnsavedChanges)
        await editor.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
        let otherID = UUID()
        await review.refresh(projectID: otherID, root: other.path)
        await review.selectPath("other", projectID: otherID, root: other.path)
        let snapshot = review.snapshot
        await review.fileDidChange("file", deleted: false, projectID: id, root: root.path)
        XCTAssertEqual(review.snapshot, snapshot); XCTAssertEqual(review.selectedPath, "other")
    }
}
