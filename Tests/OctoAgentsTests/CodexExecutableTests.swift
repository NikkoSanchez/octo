import XCTest
@testable import OctoAgents

final class CodexExecutableTests: XCTestCase {
    func testBundledPreferenceCustomOverrideAndMissingOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Desktop App/codex")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("path-codex")
        for url in [bundle, path] {
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        XCTAssertEqual(CodexExecutable.resolve(customPath: nil, bundledPaths: [bundle.path], pathExecutable: path), bundle)
        XCTAssertEqual(CodexExecutable.resolve(customPath: path.path, bundledPaths: [bundle.path], pathExecutable: path), path)
        XCTAssertEqual(CodexExecutable.resolve(customPath: nil, bundledPaths: ["/missing"], pathExecutable: path), path)
        XCTAssertNil(CodexExecutable.resolve(customPath: "/missing", bundledPaths: [bundle.path], pathExecutable: path))
        XCTAssertNil(CodexExecutable.executable(at: root.path), "Directories are not executable files")
        XCTAssertNil(CodexExecutable.executable(at: "relative/codex"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        XCTAssertEqual(CodexExecutable.resolve(customPath: nil, bundledPaths: [bundle.path], pathExecutable: path), path)
    }
}
