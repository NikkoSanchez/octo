import Foundation
import OctoCore

/// Claude Agent SDK control protocol over NDJSON. No SDK runtime or second MCP client.
@MainActor final class ClaudeConnection {
    let transport = JSONLineProcess()
    var onObject: (([String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var closed = false

    init() {
        transport.onObject = { [weak self] object in self?.receive(object) }
        transport.onExit = { [weak self] _, detail in
            self?.disconnect(detail.isEmpty ? "Claude connection closed before a result." : detail)
        }
    }
    func start(executable: URL, directory: String, arguments: [String]) throws {
        try transport.start(executable: executable, arguments: arguments, directory: directory)
    }
    func request(_ request: [String: Any], timeout: Duration = .seconds(30)) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !closed else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                do { try transport.write(["type": "control_request", "request_id": id, "request": request]) }
                catch { settle(id, result: .failure(error)); return }
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.settle(id, result: .failure(ProcessFailure.exited("Claude control request timed out.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle(id, result: .failure(CancellationError())) }
        }
    }
    func respond(id: String, response: [String: Any]) throws {
        guard !closed else { throw ProcessFailure.exited("Claude request is no longer active.") }
        try transport.write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }
    func reject(id: String, message: String) throws {
        try transport.write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": message]])
    }
    private func receive(_ object: [String: Any]) {
        guard !closed else { return }
        if object["type"] as? String == "control_response", let response = object["response"] as? [String: Any], let id = response["request_id"] as? String {
            if response["subtype"] as? String == "error" {
                settle(id, result: .failure(ProcessFailure.exited(response["error"] as? String ?? "Claude control request failed.")))
            } else if response["subtype"] as? String == "success" {
                settle(id, result: .success(response["response"] as? [String: Any] ?? [:]))
            }
        } else { onObject?(object) }
    }
    private func settle(_ id: String, result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func disconnect(_ detail: String) {
        guard !closed else { return }
        close(with: ProcessFailure.exited(detail)); onDisconnect?(detail)
    }
    func close() { close(with: CancellationError()) }
    private func close(with error: Error) {
        closed = true
        for id in Array(pending.keys) { settle(id, result: .failure(error)) }
        transport.stop()
    }
    /// Let the CLI persist/close normally after its result, with a bounded fallback.
    func finish() {
        closed = true
        transport.closeInput()
        let process = transport
        Task { try? await Task.sleep(for: .seconds(2)); process.stop() }
    }
}
