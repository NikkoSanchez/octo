import Foundation
import CoreFoundation
import OctoCore

@MainActor public final class CodexHarness: AgentHarness {
    public var onEvent: ((AgentEvent) -> Void)?
    private let rpc = RPCConnection()
    private var threadID: String?
    private var turnID: String?
    // Retain the completed turn's identity for usage delivered just after turn/completed.
    private var usageTurnID: String?
    private var compactions: [String: ContextCompaction] = [:]
    private var busy = false
    private var initialized = false
    private var streamedItems = Set<String>()
    private var reasoningItems = Set<String>()
    private var commentaryItems = Set<String>()
    private var autoReviewVerified = false
    private var extendedInteractions = false
    private var connectionID = UUID()
    private var turnEpoch = UUID()
    private var acceptingRequests = false
    private struct PendingInteraction {
        let wireID: Any
        let key: String
        let connection: UUID
        let epoch: UUID
        let decoded: CodexInteraction
    }
    private var interactions: [UUID: PendingInteraction] = [:]
    private var approvalKeys: [String: (id: String, epoch: UUID)] = [:]
    private var seenRequests = Set<String>()
    private var tools: [String: ToolActivity] = [:]
    private let executableOverride: URL?
    public init(executable: URL? = nil) {
        executableOverride = executable
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params) }
        rpc.onRequest = { [weak self] id, method, params in self?.serverRequest(id, method, params) }
        rpc.onDisconnect = { [weak self] detail in
            guard let self else { return }; self.initialized = false
            self.invalidateRequests(); self.endTools(); self.acceptingRequests = false
            if self.busy { self.busy = false; self.onEvent?(.failed(CodexToolDetails.text(detail))) }
        }
    }
    public func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings = AgentSettings(), images: [ImageAttachment] = []) async throws {
        guard !busy else { throw ProcessFailure.exited("This thread already has a running turn.") }
        guard let executable = executableOverride ?? CodexExecutable.resolve() else { throw ProcessFailure.missing("codex") }
        busy = true; acceptingRequests = true; turnID = nil; turnEpoch = UUID()
        usageTurnID = nil; compactions.removeAll()
        let epoch = turnEpoch
        do {
        let mode = settings.permissionMode ?? .ask
        if mode == .autoReview && !autoReviewVerified {
            let version = try await CodexExecutable.version(of: executable)
            try requireActive(epoch)
            guard Self.supportsAutoReview(version: version) else {
                throw ProcessFailure.exited("Approve for me requires Codex CLI 0.158.0 or newer. Choose Ask for approval or select a supported CLI in Settings.")
            }
            autoReviewVerified = true
        }
        if !rpc.running {
            connectionID = UUID(); seenRequests.removeAll(); tools.removeAll()
            let version = (try? await CodexExecutable.version(of: executable)) ?? ""
            try requireActive(epoch)
            extendedInteractions = Self.supportsInteractionExtensions(version: version)
            try rpc.start(executable: executable, directory: directory)
            var initialize: [String: Any] = ["clientInfo": ["name": "octo", "title": "Octo", "version": "0.1.0"]]
            if extendedInteractions { initialize["capabilities"] = ["experimentalApi": true, "mcpServerOpenaiFormElicitation": true] }
            _ = try await rpc.request("initialize", initialize)
            try requireActive(epoch)
            try rpc.notify("initialized"); initialized = true; threadID = nil
        }
        guard initialized else { throw ProcessFailure.exited("Codex connection is not initialized.") }
        if threadID == nil {
            var params: [String: Any] = ["cwd": directory, "approvalPolicy": Self.approvalPolicy(mode),
                                       "approvalsReviewer": mode == .autoReview ? "auto_review" : "user", "sandbox": Self.sandboxMode(mode)]
            if let sessionID { params["threadId"] = sessionID }
            if let model = settings.model { params["model"] = model }
            let result = try await rpc.request(sessionID == nil ? "thread/start" : "thread/resume", params)
            try requireActive(epoch)
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw ProcessFailure.exited("Codex returned no thread ID.") }
            threadID = id; onEvent?(.session(id))
        }
        guard let threadID else { return }
        tools.removeAll()
        streamedItems.removeAll()
        reasoningItems.removeAll()
        commentaryItems.removeAll()
            var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
            input += images.map { ["type": "image", "url": "data:image/png;base64," + $0.pngData.base64EncodedString()] }
            var params: [String: Any] = ["threadId": threadID, "input": input, "cwd": directory,
                                       "approvalPolicy": Self.approvalPolicy(mode),
                                       "approvalsReviewer": mode == .autoReview ? "auto_review" : "user",
                                       "sandboxPolicy": Self.sandboxPolicy(mode, directory: directory)]
            if let model = settings.model { params["model"] = model }
            if let effort = settings.reasoningEffort { params["effort"] = effort }
            let result = try await rpc.request("turn/start", params)
            if busy && turnEpoch == epoch {
                turnID = (result["turn"] as? [String: Any])?["id"] as? String
                usageTurnID = turnID
            }
        } catch {
            if turnEpoch == epoch { busy = false; acceptingRequests = false; invalidateRequests(); endTools() }
            throw error
        }
    }
    private func requireActive(_ epoch: UUID) throws {
        guard busy, acceptingRequests, turnEpoch == epoch else { throw ProcessFailure.exited("Turn startup was cancelled.") }
    }
    /// Conservative implementation baseline, separately declared from permission support.
    public static func supportsInteractionExtensions(version: String) -> Bool { supportsAutoReview(version: version) }
    public static let permissionOptions: [AgentPermissionOption] = [
        .init(mode: .readOnly, detail: "Read files. File writes and network access stay blocked; no escalation requests."),
        .init(mode: .ask, detail: "Edit this workspace. Ask before leaving the sandbox or accessing the network."),
        .init(mode: .autoReview, detail: "Edit this workspace. Codex reviews requests to leave the sandbox. Requires CLI 0.158.0 or newer."),
        .init(mode: .fullAccess, detail: "Unrestricted file and network access, without approval prompts.")
    ]
    public static func supportsAutoReview(version: String) -> Bool {
        guard let number = version.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { return false }
        let parts = number.split(separator: ".").prefix(2).compactMap { Int($0) }
        return parts.count == 2 && (parts[0] > 0 || parts[1] >= 158)
    }
    private static func approvalPolicy(_ mode: AgentPermissionMode) -> String {
        mode == .readOnly || mode == .fullAccess ? "never" : "on-request"
    }
    private static func sandboxMode(_ mode: AgentPermissionMode) -> String {
        switch mode { case .readOnly: return "read-only"; case .fullAccess: return "danger-full-access"; default: return "workspace-write" }
    }
    private static func sandboxPolicy(_ mode: AgentPermissionMode, directory: String) -> [String: Any] {
        switch mode {
        case .readOnly: return ["type": "readOnly", "networkAccess": false]
        case .fullAccess: return ["type": "dangerFullAccess"]
        default: return ["type": "workspaceWrite", "writableRoots": [directory], "networkAccess": false]
        }
    }
    /// Read-only account endpoint; never starts a thread or turn.
    public static func usage(directory: String, executable: URL? = nil) async throws -> AgentUsage {
        guard let executable = executable ?? CodexExecutable.resolve() else { throw ProcessFailure.missing("codex") }
        let connection = RPCConnection()
        defer { connection.close() }
        try connection.start(executable: executable, directory: directory)
        _ = try await connection.request("initialize", ["clientInfo": ["name": "octo", "title": "Octo", "version": "0.1.0"]])
        try connection.notify("initialized")
        return try decodeUsage(await connection.request("account/rateLimits/read", [:]))
    }
    static func decodeUsage(_ payload: [String: Any]) throws -> AgentUsage {
        struct Window: Decodable { var usedPercent: Double?; var windowDurationMins: Int?; var resetsAt: Double? }
        struct Bucket: Decodable { var limitId: String?; var limitName: String?; var primary: Window?; var secondary: Window? }
        struct Response: Decodable { var rateLimits: Bucket?; var rateLimitsByLimitId: [String: Bucket]? }
        let response = try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: payload))
        let entries: [String: Bucket]
        if let buckets = response.rateLimitsByLimitId, !buckets.isEmpty { entries = buckets }
        else if let bucket = response.rateLimits { entries = [bucket.limitId ?? "codex": bucket] }
        else { throw ProcessFailure.exited("The CLI returned no account usage limits.") }
        return AgentUsage(buckets: entries.keys.sorted().map { key in
            let bucket = entries[key]!
            let windows = [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { id, value -> AgentUsageWindow? in
                guard let value else { return nil }
                return AgentUsageWindow(id: id, usedPercent: value.usedPercent, durationMinutes: value.windowDurationMins,
                                        resetsAt: value.resetsAt.map { Date(timeIntervalSince1970: $0) })
            }
            return AgentUsageBucket(id: key, title: bucket.limitName ?? bucket.limitId ?? key, windows: windows)
        }, fetchedAt: Date())
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
        if method == "thread/tokenUsage/updated" {
            guard let threadID, let usageTurnID, p["threadId"] as? String == threadID,
                  p["turnId"] as? String == usageTurnID,
                  let usage = try? Self.decodeConversationUsage(p) else { return }
            onEvent?(.conversationUsage(usage)); return
        }
        if let id = p["threadId"] as? String, let threadID, id != threadID { return }
        if let id = p["turnId"] as? String, let turnID, id != turnID { return }
        if method == "turn/completed", let id = (p["turn"] as? [String: Any])?["id"] as? String, let turnID, id != turnID { return }
        if !busy && method != "account/rateLimits/updated" && method != "serverRequest/resolved" { return }
        switch method {
        case "item/mcpToolCall/progress":
            guard p["threadId"] as? String == threadID, p["turnId"] as? String == turnID,
                  let id = p["itemId"] as? String, var tool = tools[id], tool.state == .running else { return }
            tool.detail = CodexToolDetails.text(p["message"] as? String ?? "")
            if tools[id] != tool { tools[id] = tool; onEvent?(.toolActivity(tool)) }
        case "turn/started":
            if let id = (p["turn"] as? [String: Any])?["id"] as? String, turnID == nil || turnID == id { turnID = id; usageTurnID = id }
        case "item/agentMessage/delta":
            if let id = p["itemId"] as? String { streamedItems.insert(id) }
            if let delta = p["delta"] as? String {
                onEvent?(commentaryItems.contains(p["itemId"] as? String ?? "") ? .activityDelta(delta) : .textDelta(delta))
            }
        case "item/reasoning/summaryTextDelta":
            if let id = p["itemId"] as? String { reasoningItems.insert(id) }
            if let delta = p["delta"] as? String { onEvent?(.reasoningDelta(delta)) }
        case "item/reasoning/summaryPartAdded":
            if let id = p["itemId"] as? String, reasoningItems.contains(id) { onEvent?(.reasoningDelta("\n\n")) }
        case "account/rateLimits/updated":
            if let usage = try? Self.decodeUsage(p) { onEvent?(.usage(usage)) }
        case "item/started", "item/completed":
            guard let item = p["item"] as? [String: Any], let type = item["type"] as? String else { return }
            if type == "contextCompaction" {
                guard acceptingRequests, let threadID, let turnID, p["threadId"] as? String == threadID,
                      p["turnId"] as? String == turnID, let id = item["id"] as? String, !id.isEmpty else { return }
                let state: ContextCompaction.State = method == "item/started" ? .compacting : .completed
                if let previous = compactions[id], previous.state == state || previous.state != .compacting { return }
                var compaction = compactions[id] ?? ContextCompaction(id: "\(connectionID):\(turnEpoch):\(id)", state: state)
                compaction.state = state
                if state == .completed { compaction.endedAt = Date() }
                compactions[id] = compaction; onEvent?(.compaction(compaction))
                return
            }
            if type == "mcpToolCall" {
                guard p["threadId"] as? String == threadID, p["turnId"] as? String == turnID,
                      let id = item["id"] as? String, let server = item["server"] as? String, let name = item["tool"] as? String else { return }
                if let previous = tools[id], previous.state != .running { return }
                let state: ToolActivity.State = item["status"] as? String == "failed" ? .failed : (method == "item/completed" ? .completed : .running)
                let tool = ToolActivity(id: "\(connectionID):\(turnEpoch):\(id)", server: CodexToolDetails.text(server, limit: 256), tool: CodexToolDetails.text(name, limit: 256), state: state, detail: CodexToolDetails.result(item))
                if tools[id] != tool { tools[id] = tool; onEvent?(.toolActivity(tool)) }
            }
            if type == "agentMessage", item["phase"] as? String == "commentary", method == "item/started" {
                if let id = item["id"] as? String { commentaryItems.insert(id) }
                onEvent?(.activity(""))
            }
            if type == "agentMessage", method == "item/completed", let text = item["text"] as? String,
               !streamedItems.contains(item["id"] as? String ?? "") {
                if item["phase"] as? String == "commentary" {
                    onEvent?(commentaryItems.contains(item["id"] as? String ?? "") ? .activityDelta(text) : .activity(text))
                } else { onEvent?(.message(text)) }
            }
            if type == "reasoning", method == "item/completed", !reasoningItems.contains(item["id"] as? String ?? ""),
               let summary = item["summary"] as? [String], !summary.isEmpty { onEvent?(.reasoningDelta(summary.joined(separator: "\n\n"))) }
            if method == "item/started", type == "commandExecution" { onEvent?(.activity(item["command"] as? String ?? "Running command")) }
            if method == "item/completed", type == "fileChange" { onEvent?(.activity("Updated files")) }
        case "turn/completed":
            invalidateRequests(); endTools(); acceptingRequests = false
            busy = false; turnID = nil
            let turn = p["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed" {
                let error = turn["error"] as? [String: Any]; onEvent?(.failed(error?["message"] as? String ?? "Codex turn failed."))
            } else { onEvent?(.finished) }
        case "serverRequest/resolved":
            guard let wireID = p["requestId"], let key = Self.requestKey(wireID) else { return }
            for (id, pending) in interactions where pending.key == key { interactions[id] = nil; onEvent?(.interactionResolved(id)) }
            if let approval = approvalKeys.removeValue(forKey: key) { onEvent?(.approvalResolved(approval.id)) }
        case "error":
            if p["willRetry"] as? Bool != true { let error = p["error"] as? [String: Any]; onEvent?(.activity(error?["message"] as? String ?? "Codex reported an error.")) }
        default: break
        }
    }
    private static func requestKey(_ id: Any) -> String? {
        if let string = id as? String { return "string:" + string }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return "number:" + number.stringValue }
        return nil
    }
    private func serverRequest(_ id: Any, _ method: String, _ p: [String: Any]) {
        guard let key = Self.requestKey(id), seenRequests.insert(key).inserted else { return }
        let elicitation = method == "mcpServer/elicitation/request"
        let questions = method == "item/tool/requestUserInput"
        guard busy, acceptingRequests,
              (p["threadId"] as? String == nil || p["threadId"] as? String == threadID),
              (p["turnId"] as? String == nil || p["turnId"] as? String == turnID) else {
            if elicitation { rpc.respond(id: id, result: ["action": "cancel", "content": NSNull()]) }
            else if questions { rpc.respond(id: id, result: ["answers": [:]]) }
            else { rpc.reject(id: id, method: method) }
            return
        }
        if elicitation || questions {
            do {
                guard let owner = threadID, p["threadId"] as? String == owner,
                      (questions || (p["serverName"] as? String)?.isEmpty == false),
                      (!questions || ((p["itemId"] as? String)?.isEmpty == false && p["isBlocking"] is Bool)),
                      (!questions || (extendedInteractions && p["turnId"] as? String == turnID)),
                      (p["mode"] as? String == "form" || questions || extendedInteractions) else {
                    throw ProcessFailure.exited("Unsupported interaction context or experimental API; use a supported Codex CLI (0.158 or newer).")
                }
                let decoded = try CodexInteraction.decode(p, questions: questions)
                interactions[decoded.request.id] = PendingInteraction(wireID: id, key: key, connection: connectionID, epoch: turnEpoch, decoded: decoded)
                onEvent?(.interaction(decoded.request))
            } catch {
                rpc.respond(id: id, result: questions ? ["answers": [:]] : ["action": "decline", "content": NSNull()])
                onEvent?(.interactionUnavailable(error.localizedDescription))
            }
        } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            let detail = [p["command"] as? String, p["cwd"] as? String, p["reason"] as? String, p["grantRoot"] as? String].compactMap { $0 }.joined(separator: "\n")
            let localID = UUID().uuidString, epoch = turnEpoch, connection = connectionID
            approvalKeys[key] = (localID, epoch)
            onEvent?(.approval(.init(id: localID, title: method.contains("commandExecution") ? "Command approval" : "File change approval", detail: detail.isEmpty ? "The agent requests permission for this operation." : detail, respond: { [weak self] allow in
                guard let self, self.connectionID == connection, self.turnEpoch == epoch,
                      self.approvalKeys[key]?.id == localID, self.acceptingRequests else { return }
                self.approvalKeys[key] = nil
                self.rpc.respond(id: id, result: ["decision": allow ? "accept" : "decline"])
                self.onEvent?(.approvalResolved(localID))
            })))
        } else if method == "item/permissions/requestApproval" {
            rpc.respond(id: id, result: ["permissions": [:], "scope": "turn"])
            onEvent?(.interactionUnavailable("Additional permission request declined: this request type is not yet supported."))
        } else {
            rpc.reject(id: id, method: method); onEvent?(.interactionUnavailable("Unsupported agent request: \(method)"))
        }
    }
    public func respond(to id: UUID, with response: AgentInteractionResponse) throws {
        guard let pending = interactions[id], pending.connection == connectionID, pending.epoch == turnEpoch,
              busy, acceptingRequests, rpc.running else { throw ProcessFailure.exited("This request is no longer active.") }
        let result = try pending.decoded.response(response)
        try rpc.sendResponse(id: pending.wireID, result: result)
        interactions[id] = nil; onEvent?(.interactionResolved(id))
    }
    private func invalidateRequests(cancel: Bool = false) {
        let pending = interactions; interactions.removeAll()
        for (id, request) in pending {
            if cancel, let result = try? request.decoded.response(.cancel) { rpc.respond(id: request.wireID, result: result) }
            onEvent?(.interactionResolved(id))
        }
        for approval in approvalKeys.values { onEvent?(.approvalResolved(approval.id)) }
        approvalKeys.removeAll()
    }
    private func endTools() {
        for (id, var tool) in tools where tool.state == .running {
            tool.state = .interrupted; tools[id] = tool; onEvent?(.toolActivity(tool))
        }
    }
    public func interrupt() async {
        acceptingRequests = false; invalidateRequests(cancel: true); endTools()
        guard let threadID, let turnID else {
            if busy { rpc.close(); busy = false; initialized = false; onEvent?(.finished) }
            return
        }
        _ = try? await rpc.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
    }
    public func shutdown() { acceptingRequests = false; usageTurnID = nil; invalidateRequests(cancel: true); endTools(); busy = false; rpc.close() }
}
