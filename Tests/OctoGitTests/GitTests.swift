import XCTest
import OctoCore
@testable import OctoGit

final class GitTests: XCTestCase {
    func testStatusKeepsRenameDestinationAndSpaces() {
        let files = GitService.parseStatus(Data("R  new name.swift\0old name.swift\0?? café.txt\0 M existing.swift\0".utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.path == "new name.swift" && $0.hasStaged })
        XCTAssertFalse(files.contains { $0.path == "old name.swift" })
        XCTAssertTrue(files.contains { $0.path == "café.txt" && $0.isUntracked })
    }
    func testHunkLineNumbersAndMissingFinalNewline() {
        let lines = UnifiedDiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -4,2 +4,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n")
        XCTAssertEqual(lines.filter { $0.kind == .deletion }.first?.oldLine, 5)
        XCTAssertEqual(lines.filter { $0.kind == .addition }.first?.newLine, 5)
        XCTAssertEqual(lines.filter { $0.kind == .context }.first?.newLine, 4)
    }
    func testRealRepositorySeparatesIndexAndWorkingTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try XCTUnwrap(Executables.find("git"))
        func run(_ args: [String]) async throws {
            let result = try await ProcessRunner.run(git, arguments: args, directory: root)
            XCTAssertEqual(result.status, 0, String(decoding: result.error, as: UTF8.self))
        }
        try await run(["init", "-b", "main"])
        let file = root.appendingPathComponent("file with spaces.swift")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await run(["add", "--", file.lastPathComponent])
        try await run(["-c", "user.name=Octo Test", "-c", "user.email=octo@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"])
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try await run(["add", "--", file.lastPathComponent])
        try "working\n".write(to: file, atomically: true, encoding: .utf8)
        let service = GitService(), projectID = UUID()
        let files = try await service.changes(root: root.path)
        let change = try XCTUnwrap(files.first)
        XCTAssertTrue(change.hasStaged && change.hasWorking)
        let staged = try await service.snapshot(file: change, projectID: projectID, root: root.path, scope: .staged)
        let working = try await service.snapshot(file: change, projectID: projectID, root: root.path, scope: .working)
        XCTAssertEqual(staged.lines.filter { $0.kind == .addition }.map(\.text), ["staged"])
        XCTAssertEqual(working.lines.filter { $0.kind == .addition }.map(\.text), ["working"])
        XCTAssertEqual(working.lines.filter { $0.kind == .deletion }.map(\.text), ["staged"])
        let paths = try await service.filePaths(root: root.path)
        XCTAssertEqual(paths, [file.lastPathComponent])
        let source = try await service.fileSnapshot(path: file.lastPathComponent, projectID: projectID, root: root.path)
        XCTAssertEqual(source.scope, .file)
        XCTAssertEqual(source.lines.map(\.text), ["working"])
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        do {
            _ = try await service.fileSnapshot(path: "external", projectID: projectID, root: root.path)
            XCTFail("Must not preview a symlink outside the checkout")
        } catch { /* Expected boundary rejection. */ }
    }
    func testBothPreviewsRejectTraversalAncestorLinksAndSpecialFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try "private".write(to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let service = GitService(), id = UUID()
        for path in ["link/secret", "../outside", outside.appendingPathComponent("secret").path] {
            do { _ = try await service.fileSnapshot(path: path, projectID: id, root: root.path); XCTFail("Unexpected preview") } catch {}
            do { _ = try await service.snapshot(file: .init(path: path, indexStatus: "?", worktreeStatus: "?"), projectID: id, root: root.path, scope: .working); XCTFail("Unexpected preview") } catch {}
        }
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let snapshot = try await service.snapshot(file: .init(path: "folder", indexStatus: "?", worktreeStatus: "?"), projectID: id, root: root.path, scope: .working)
        XCTAssertNotNil(snapshot.notice); XCTAssertTrue(snapshot.lines.isEmpty)
    }
}
