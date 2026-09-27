import Foundation
import OctoCore

/// Use one resolution policy for discovery and generation. A user override never
/// silently falls back to a different installation if it disappears.
public enum CodexExecutable {
    public static var bundledPaths: [String] {
        ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path].flatMap { root in
            ["\(root)/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             "\(root)/Codex.app/Contents/Resources/codex"]
        }
    }

    public static func resolve(customPath: String? = nil) -> URL? {
        resolve(customPath: customPath, bundledPaths: bundledPaths, pathExecutable: Executables.find("codex"))
    }

    static func resolve(customPath: String?, bundledPaths: [String], pathExecutable: URL?) -> URL? {
        if let customPath { return executable(at: customPath) }
        return bundledPaths.compactMap { executable(at: $0) }.first ?? pathExecutable
    }

    public static func executable(at path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func version(of executable: URL) async throws -> String {
        let result = try await ProcessRunner.run(executable, arguments: ["--version"], directory: executable.deletingLastPathComponent())
        guard result.status == 0 else { throw ProcessFailure.exited("Could not read Codex version.") }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
