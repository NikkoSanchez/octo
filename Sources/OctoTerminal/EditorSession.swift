import Foundation
import OctoCore

/// A completion marker distinguishes editor startup from exit, even if no socket was created.
final class EditorSession {
    private let directory: PrivateTemporaryDirectory
    let socket: String
    let completion: URL

    init() throws {
        directory = try PrivateTemporaryDirectory()
        socket = directory.url.appendingPathComponent("nvim.sock").path
        completion = directory.url.appendingPathComponent("exited")
    }

    var hasExited: Bool { FileManager.default.fileExists(atPath: completion.path) }

    func command(editor: URL, file: URL, line: Int, shell: String = EditorSession.loginShell) -> String {
        let editorCommand = [editor.path, "--listen", socket, "+\(max(1, line))", "--", file.path]
            .map(Executables.shellQuote).joined(separator: " ")
        // Ghostty owns this shell and PTY throughout. Continue even on an editor launch/error exit.
        // Every dynamic value is quoted at this explicit terminal launch boundary.
        let script = editorCommand + "; : > " + Executables.shellQuote(completion.path)
            + "; exec " + Executables.shellQuote(shell) + " -l -i"
        return ["/bin/sh", "-c", script].map(Executables.shellQuote).joined(separator: " ")
    }

    static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }
}
