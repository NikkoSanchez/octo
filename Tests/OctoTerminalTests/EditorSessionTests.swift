import XCTest
import OctoCore
@testable import OctoTerminal

final class EditorSessionTests: XCTestCase {
    func testEditorExitStartsShellWithLiteralPathsAndUsableInput() async throws {
        let directory = try PrivateTemporaryDirectory()
        let editor = directory.url.appendingPathComponent("editor ' $(literal)")
        let shell = directory.url.appendingPathComponent("shell ' $(literal)")
        let file = directory.url.appendingPathComponent("file ' ; $(literal).txt")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 17\n".utf8).write(to: editor)
        try Data("#!/bin/sh\nprintf 'SHELL:%s:%s\\n' \"$1\" \"$2\"\nread -r line\nprintf 'INPUT:%s\\n' \"$line\"\npwd\n".utf8).write(to: shell)
        for executable in [editor, shell] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let session = try EditorSession()
        XCTAssertFalse(session.hasExited, "Startup without a socket is not an exited editor")
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", session.command(editor: editor, file: file, line: 12, shell: shell.path)],
            directory: directory.url, input: Data("still usable\n".utf8))
        XCTAssertEqual(result.status, 0)
        let output = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(output.contains("--listen\n\(session.socket)\n+12\n--\n\(file.path)\n"), output)
        XCTAssertTrue(output.contains("SHELL:-l:-i\nINPUT:still usable\n"), output)
        XCTAssertTrue(output.contains(directory.url.resolvingSymlinksInPath().path), output)
        XCTAssertTrue(session.hasExited)
    }

    func testFailedEditorLaunchStillReturnsToInteractiveShell() async throws {
        let session = try EditorSession()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", session.command(editor: URL(fileURLWithPath: "/missing-octo-editor"),
                file: URL(fileURLWithPath: "/tmp/unused"), line: 0, shell: "/bin/sh")],
            directory: URL(fileURLWithPath: "/tmp"), input: Data("printf 'SHELL_READY\\n'\nexit\n".utf8))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("SHELL_READY"))
        XCTAssertTrue(session.hasExited)
    }

    @MainActor func testExitRetiresEditorIdentityWithoutReplacingTerminalAndReleasesSocketDirectory() async throws {
        var session: EditorSession? = try EditorSession()
        let completion = try XCTUnwrap(session?.completion)
        let directory = completion.deletingLastPathComponent()
        let tab = TerminalTab(projectID: UUID(), directory: "/tmp", label: "file.txt", editorSession: session)
        let state = tab.state
        session = nil
        tab.refreshEditorSession()
        XCTAssertNotNil(tab.editorSocket)
        try Data().write(to: completion)
        for _ in 0..<50 {
            if tab.editorSocket == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(tab.editorSocket)
        XCTAssertEqual(tab.label, "Terminal")
        XCTAssertFalse(tab.exited, "The shell still owns this tab")
        XCTAssertTrue(tab.state === state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testClosingBeforeEditorStartupReleasesSessionAndMonitor() throws {
        var session: EditorSession? = try EditorSession()
        let directory = try XCTUnwrap(session?.completion.deletingLastPathComponent())
        var tab: TerminalTab? = TerminalTab(projectID: UUID(), directory: "/tmp", label: "file.txt", editorSession: session)
        weak var weakTab = tab
        session = nil
        tab = nil
        XCTAssertNil(weakTab)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
