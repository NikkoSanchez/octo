import Foundation
import OctoCore

struct JSONLineFramer {
    let limit: Int
    private var buffer = Data()
    init(limit: Int = 8_000_000) { self.limit = limit }
    mutating func receive(_ data: Data, emit: (Data) -> Void) throws {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            guard data.distance(from: start, to: end) <= limit - buffer.count else { throw ProcessFailure.oversized }
            buffer.append(contentsOf: data[start..<end])
            if let newline { emit(buffer); buffer.removeAll(keepingCapacity: true); start = data.index(after: newline) }
            else { break }
        }
    }
    mutating func finish(emit: (Data) -> Void) { if !buffer.isEmpty { emit(buffer) }; buffer.removeAll() }
}

/// Main-actor protocol state, with backpressure to bounded background pipe I/O.
@MainActor final class JSONLineProcess {
    var onObject: (([String: Any]) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private var process: ManagedSubprocess?
    private var framer = JSONLineFramer()
    private var stderr = Data()
    private var framingFailed = false
    var running: Bool { process?.running == true }

    func start(executable: URL, arguments: [String], directory: String) throws {
        guard process == nil else { throw ProcessFailure.exited("Previous agent process is still closing. Try again shortly.") }
        framer = JSONLineFramer(); stderr = Data(); framingFailed = false
        process = try ManagedSubprocess.launch(executable: executable, arguments: arguments,
            directory: URL(fileURLWithPath: directory),
            environment: ProcessInfo.processInfo.environment.merging(["PATH": Executables.searchPath, "NO_COLOR": "1"]) { _, new in new },
            onOutput: { [weak self] data in DispatchQueue.main.sync { self?.receive(data) } },
            onError: { [weak self] data in DispatchQueue.main.sync {
                guard let self, !self.framingFailed else { return }
                self.stderr.append(data); self.stderr = Data(self.stderr.suffix(8192))
            } },
            onExit: { [weak self] status, failure in DispatchQueue.main.async {
                guard let self else { return }
                if !self.framingFailed { self.framer.finish { self.decode($0) } }
                let detail = failure?.localizedDescription ?? String(decoding: self.stderr, as: UTF8.self)
                self.process = nil; self.onExit?(self.framingFailed ? 1 : status, detail)
            } })
    }
    private func receive(_ data: Data) {
        guard !framingFailed else { return }
        do { try framer.receive(data) { self.decode($0) } }
        catch { framingFailed = true; stderr = Data("Agent protocol frame exceeds 8 MB.".utf8); process?.stop() }
    }
    private func decode(_ line: Data) {
        guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        onObject?(object)
    }
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        guard let process, running else { throw ProcessFailure.exited("Agent process is not running.") }
        try process.send(data)
    }
    func writeInput(_ text: String) throws {
        guard let process else { throw ProcessFailure.exited("Agent process is not running.") }
        try process.send(Data(text.utf8), closeInput: true)
    }
    func closeInput() { try? process?.send(Data(), closeInput: true) }
    func interrupt() { process?.interrupt() }
    func stop() { process?.stop() }
    deinit { process?.stop() }
}

@MainActor final class RPCConnection {
    private let transport = JSONLineProcess()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((Any, String, [String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var running: Bool { transport.running }
    init() {
        transport.onObject = { [weak self] object in self?.receive(object) }
        transport.onExit = { [weak self] _, detail in self?.disconnected(detail.isEmpty ? "Agent connection closed." : detail) }
    }
    func start(executable: URL, directory: String) throws { try transport.start(executable: executable, arguments: ["app-server"], directory: directory) }
    func request(_ method: String, _ params: [String: Any], timeout: Duration = .seconds(45)) async throws -> [String: Any] {
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try transport.write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.pending.removeValue(forKey: id)?.resume(throwing: ProcessFailure.exited("Agent request timed out: \(method)"))
            }
        }
    }
    func notify(_ method: String) throws { try transport.write(["method": method, "params": [:]]) }
    func sendResponse(id: Any, result: [String: Any]) throws { try transport.write(["id": id, "result": result]) }
    func respond(id: Any, result: [String: Any]) { try? transport.write(["id": id, "result": result]) }
    func reject(id: Any, method: String) { try? transport.write(["id": id, "error": ["code": -32601, "message": "Octo does not yet support \(method)"]]) }
    private func receive(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"] { onRequest?(id, method, params) } else { onNotification?(method, params) }
        } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] { continuation.resume(throwing: ProcessFailure.exited(error["message"] as? String ?? "Agent request failed.")) }
            else { continuation.resume(returning: object["result"] as? [String: Any] ?? [:]) }
        }
    }
    private func disconnected(_ detail: String) {
        let callbacks = pending.values; pending.removeAll()
        callbacks.forEach { $0.resume(throwing: ProcessFailure.exited(detail)) }; onDisconnect?(detail)
    }
    func close() { transport.stop(); disconnected("Agent connection closed.") }
}
