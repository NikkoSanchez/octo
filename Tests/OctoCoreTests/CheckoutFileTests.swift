import XCTest
import Darwin
@testable import OctoCore

final class CheckoutFileTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octo-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func rejects(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unexpected filesystem mutation", file: file, line: line) } catch {}
    }
    func testCreateSaveDeletePreservesExactSourceAndExecutableMode() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let path = "folder/café ' $ file.swift", service = CheckoutFileService()
        try await service.create(path: path, root: root.path)
        let url = root.appendingPathComponent(path)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        let original = "// 🐙\r\n\tlet value = 1\r\n\r\nno final newline"
        try Data(original.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o755), 0)
        let document = try await service.inspect(path: path, root: root.path, forEditing: true)
        XCTAssertEqual(document.text, original)
        let replacement = original.replacingOccurrences(of: "1", with: "2")
        try await service.save(document, text: replacement)
        XCTAssertEqual(try Data(contentsOf: url), Data(replacement.utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("folder").path).contains { $0.hasPrefix(".octo-save-") })
        let deletion = try await service.inspect(path: path, root: root.path, forEditing: false)
        try await service.delete(deletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCreateNeverOverwritesExistingEntries() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckoutFileService(), url = root.appendingPathComponent("existing")
        try "keep".write(to: url, atomically: true, encoding: .utf8)
        await rejects { try await service.create(path: "existing", root: root.path) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        await rejects { try await service.create(path: "folder", root: root.path) }
    }
    func testChangedReplacedAndRemovedFilesCannotBeOverwrittenOrDeleted() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckoutFileService(), url = root.appendingPathComponent("source")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let original = try await service.inspect(path: "source", root: root.path, forEditing: true)
        try Data("external".utf8).write(to: url)
        await rejects { try await service.save(original, text: "my edits") }
        await rejects { try await service.delete(original) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        let next = try await service.inspect(path: "source", root: root.path, forEditing: false)
        try "external".write(to: url, atomically: true, encoding: .utf8)
        await rejects { try await service.delete(next) }
        try FileManager.default.removeItem(at: url)
        await rejects { try await service.save(original, text: "must not recreate") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testTraversalSymlinksGitMetadataAndHardLinksAreRejected() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let service = CheckoutFileService(), secret = outside.appendingPathComponent("secret")
        try "outside".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("leaf"), withDestinationURL: secret)
        for path in ["../escape", secret.path, "link/secret", "leaf", ".git/config", ".GIT/config", "a/../b", "a//b", "bad\0name"] {
            await rejects { _ = try await service.inspect(path: path, root: root.path, forEditing: true) }
            await rejects { try await service.create(path: path, root: root.path) }
        }
        try FileManager.default.linkItem(at: secret, to: root.appendingPathComponent("hardlink"))
        await rejects { _ = try await service.inspect(path: "hardlink", root: root.path, forEditing: true) }
        await rejects { _ = try await service.inspect(path: "hardlink", root: root.path, forEditing: false) }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "outside")
    }
    func testParentReplacedWithSymlinkCannotRedirectMutation() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let service = CheckoutFileService(), folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "inside".write(to: folder.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let document = try await service.inspect(path: "folder/file", root: root.path, forEditing: true)
        try "outside".write(to: outside.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        await rejects { try await service.save(document, text: "new") }
        await rejects { try await service.delete(document) }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("file"), encoding: .utf8), "outside")
    }
    func testEditorBoundsBinaryFilesAndReadOnlyFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckoutFileService()
        for (path, data) in [("binary", Data([0, 1, 2])), ("invalid", Data([0xff])), ("large", Data(repeating: 97, count: CheckoutFileService.editorByteLimit + 1))] {
            try data.write(to: root.appendingPathComponent(path))
            await rejects { _ = try await service.inspect(path: path, root: root.path, forEditing: true) }
            let file = try await service.inspect(path: path, root: root.path, forEditing: false)
            try await service.delete(file)
        }
        let url = root.appendingPathComponent("readonly")
        try "keep".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o444), 0)
        let file = try await service.inspect(path: "readonly", root: root.path, forEditing: true)
        await rejects { try await service.save(file, text: "overwrite") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
        XCTAssertEqual(chmod(url.path, 0o644), 0)
    }
    func testRejectedDraftLeavesOriginalAndNoTemporaryFile() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckoutFileService()
        try await service.create(path: "file", root: root.path)
        let file = try await service.inspect(path: "file", root: root.path, forEditing: true)
        await rejects { try await service.save(file, text: String(repeating: "🐙", count: 500_001)) }
        await rejects { try await service.save(file, text: "bad\0data") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file"])
    }
}
