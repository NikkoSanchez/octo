import Foundation

public enum Executables {
    public static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ([ProcessInfo.processInfo.environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin", "/usr/bin", "/bin"]).joined(separator: ":")
    }
    public static func find(_ name: String) -> URL? {
        for directory in searchPath.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
public struct ProcessResult: Sendable { public var status: Int32; public var output: Data; public var error: Data }
public enum ProcessFailure: LocalizedError {
    case missing(String), exited(String), oversized, timedOut
    public var errorDescription: String? {
        switch self { case .missing(let name): return "\(name) is not installed or not on PATH."
        case .exited(let detail): return detail
        case .timedOut: return "Process exceeded its time limit."
        case .oversized: return "Output exceeds the supported size limit." }
    }
}
private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var child: ManagedSubprocess?
    private var cancelled = false
    func install(_ child: ManagedSubprocess) { lock.lock(); defer { lock.unlock() }; self.child = child; if cancelled { child.stop() } }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; child?.stop() }
}
private final class ProcessCapture: @unchecked Sendable {
    // Accessed only by the subprocess's serial background pump.
    var output = Data(), error = Data()
}
public enum ProcessRunner {
    /// `environment` adds to or replaces the inherited variables.
    public static func run(_ executable: URL, arguments: [String], directory: URL, input: Data? = nil,
                           environment: [String: String] = [:],
                           timeout: TimeInterval = 30, outputLimit: Int = 8_000_000) async throws -> ProcessResult {
        guard (input?.count ?? 0) <= 36 * 1_024 * 1_024 else { throw ProcessFailure.oversized }
        let cancellation = ProcessCancellation(), capture = ProcessCapture()
        let result: ProcessResult = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let child = try ManagedSubprocess.launch(executable: executable, arguments: arguments, directory: directory,
                        environment: ProcessInfo.processInfo.environment.merging(["PATH": Executables.searchPath, "GIT_TERMINAL_PROMPT": "0"].merging(environment) { _, new in new }) { _, new in new },
                        timeout: timeout, outputLimit: max(0, outputLimit),
                        onOutput: { capture.output.append($0) }, onError: { capture.error.append($0) },
                        onExit: { status, failure in
                            if let failure { continuation.resume(throwing: failure) }
                            else { continuation.resume(returning: ProcessResult(status: status, output: capture.output, error: capture.error)) }
                        })
                    cancellation.install(child)
                    do { try child.send(input ?? Data(), closeInput: true) } catch { child.stop() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }
}
