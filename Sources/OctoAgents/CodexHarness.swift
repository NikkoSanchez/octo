import Foundation
import OctoCore

@MainActor public final class CodexHarness: AgentHarness {
    public var onEvent: ((AgentEvent) -> Void)?
    private let rpc = RPCConnection()
    private var threadID: String?
    private var turnID: String?
    private var busy = false
    private var initialized = false
    private var streamedItems = Set<String>()
    private let executableOverride: URL?
    public init(executable: URL? = nil) {
        executableOverride = executable
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params) }
        rpc.onRequest = { [weak self] id, method, params in self?.serverRequest(id, method, params) }
        rpc.onDisconnect = { [weak self] detail in
            guard let self else { return }; self.initialized = false
            if self.busy { self.busy = false; self.onEvent?(.failed(detail)) }
        }
    }
    public func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings = AgentSettings(), images: [ImageAttachment] = []) async throws {
        guard !busy else { throw ProcessFailure.exited("This thread already has a running turn.") }
        guard let executable = executableOverride ?? CodexExecutable.resolve() else { throw ProcessFailure.missing("codex") }
        busy = true
        do {
        if !rpc.running {
            try rpc.start(executable: executable, directory: directory)
            _ = try await rpc.request("initialize", ["clientInfo": ["name": "octo", "title": "Octo", "version": "0.1.0"]])
            try rpc.notify("initialized"); initialized = true; threadID = nil
        }
        guard initialized else { throw ProcessFailure.exited("Codex connection is not initialized.") }
        if threadID == nil {
            var params: [String: Any] = ["cwd": directory, "approvalPolicy": "on-request", "sandbox": "workspace-write"]
            if let sessionID { params["threadId"] = sessionID }
            if let model = settings.model { params["model"] = model }
            let result = try await rpc.request(sessionID == nil ? "thread/start" : "thread/resume", params)
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw ProcessFailure.exited("Codex returned no thread ID.") }
            threadID = id; onEvent?(.session(id))
        }
        guard let threadID else { return }
        streamedItems.removeAll()
            var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
            input += images.map { ["type": "image", "url": "data:image/png;base64," + $0.pngData.base64EncodedString()] }
            var params: [String: Any] = ["threadId": threadID, "input": input]
            if let model = settings.model { params["model"] = model }
            if let effort = settings.reasoningEffort { params["effort"] = effort }
            let result = try await rpc.request("turn/start", params)
            if busy { turnID = (result["turn"] as? [String: Any])?["id"] as? String }
        } catch { busy = false; throw error }
    }
    /// Read-only discovery: initializes a separate connection without starting a thread or turn.
    /// Codex CLI 0.151.0 app-server v2: model/list (including pagination).
    public static func models(directory: String, executable: URL? = nil) async throws -> [AgentModel] {
        guard let executable = executable ?? CodexExecutable.resolve() else { throw ProcessFailure.missing("codex") }
        let connection = RPCConnection()
        defer { connection.close() }
        try connection.start(executable: executable, directory: directory)
        _ = try await connection.request("initialize", ["clientInfo": ["name": "octo", "title": "Octo", "version": "0.1.0"]])
        try connection.notify("initialized")
        struct Page: Decodable { let data: [AgentModel]; let nextCursor: String? }
        var models: [AgentModel] = [], cursor: String?, seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await connection.request("model/list", params)
            let page = try JSONDecoder().decode(Page.self, from: JSONSerialization.data(withJSONObject: result))
            for model in page.data where !model.hidden && !models.contains(where: { $0.id == model.id }) { models.append(model) }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw ProcessFailure.exited("Codex returned a repeated model-list cursor.") }
        } while cursor != nil
        return models
    }
    private func notification(_ method: String, _ p: [String: Any]) {
        if let id = p["threadId"] as? String, let threadID, id != threadID { return }
        switch method {
        case "turn/started": turnID = (p["turn"] as? [String: Any])?["id"] as? String
        case "item/agentMessage/delta":
            if let id = p["itemId"] as? String { streamedItems.insert(id) }
            if let delta = p["delta"] as? String { onEvent?(.textDelta(delta)) }
        case "item/started", "item/completed":
            guard let item = p["item"] as? [String: Any], let type = item["type"] as? String else { return }
            if type == "agentMessage", method == "item/completed", let text = item["text"] as? String,
               !streamedItems.contains(item["id"] as? String ?? "") { onEvent?(.message(text)) }
            if method == "item/started", type == "commandExecution" { onEvent?(.activity(item["command"] as? String ?? "Running command")) }
            if method == "item/completed", type == "fileChange" { onEvent?(.activity("Updated files")) }
        case "turn/completed":
            busy = false; turnID = nil
            let turn = p["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed" {
                let error = turn["error"] as? [String: Any]; onEvent?(.failed(error?["message"] as? String ?? "Codex turn failed."))
            } else { onEvent?(.finished) }
        case "serverRequest/resolved": if let id = p["requestId"] { onEvent?(.approvalResolved(String(describing: id))) }
        case "error":
            if p["willRetry"] as? Bool != true { let error = p["error"] as? [String: Any]; onEvent?(.activity(error?["message"] as? String ?? "Codex reported an error.")) }
        default: break
        }
    }
    private func serverRequest(_ id: Any, _ method: String, _ p: [String: Any]) {
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            let detail = [p["command"] as? String, p["cwd"] as? String, p["reason"] as? String, p["grantRoot"] as? String].compactMap { $0 }.joined(separator: "\n")
            onEvent?(.approval(.init(id: String(describing: id), title: method.contains("commandExecution") ? "Command approval" : "File change approval", detail: detail.isEmpty ? "The agent requests permission for this operation." : detail, respond: { [weak self] allow in
                self?.rpc.respond(id: id, result: ["decision": allow ? "accept" : "decline"])
            })))
        } else if method == "item/permissions/requestApproval" {
            rpc.respond(id: id, result: ["permissions": [:], "scope": "turn"])
            onEvent?(.activity("Additional permission request declined: this request type is not yet supported."))
        } else if method == "mcpServer/elicitation/request" {
            rpc.respond(id: id, result: ["action": "decline", "content": NSNull()])
            onEvent?(.activity("MCP elicitation declined: this request type is not yet supported."))
        } else {
            rpc.reject(id: id, method: method); onEvent?(.activity("Unsupported agent request: \(method)"))
        }
    }
    public func interrupt() async {
        guard let threadID, let turnID else {
            if busy { rpc.close(); busy = false; initialized = false; onEvent?(.finished) }
            return
        }
        _ = try? await rpc.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
    }
    public func shutdown() { busy = false; rpc.close() }
}
