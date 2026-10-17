import Foundation
import OctoCore

/// Uses the user's CLI/auth/settings. Each turn initializes a fresh connection and
/// resumes explicitly, so settings changes cannot inherit a broader permission mode.
@MainActor public final class ClaudeHarness: AgentHarness {
    public var onEvent: ((AgentEvent) -> Void)?
    private let executableOverride: URL?
    private var connection: ClaudeConnection?
    private var generation = UUID()
    private var active = false
    private var ready = false
    private var confirmedPermissionMode: String?
    private var remoteSession: String?
    private var streamedBlocks = Set<Int>()
    private var thinkingBlocks = Set<Int>()
    private var completedMessages = Set<String>()
    private var seenRequests = Set<String>()
    private var tools: [String: ToolActivity] = [:]
    private var approvals: [String: (localID: String, input: [String: Any])] = [:]
    private struct Question {
        let requestID: String
        let input: [String: Any]
        let interaction: AgentInteraction
    }
    private var questions: [UUID: Question] = [:]

    public init(executable: URL? = nil) { executableOverride = executable }
    public static let permissionOptions: [AgentPermissionOption] = [
        .init(mode: .ask, title: "Manual", detail: "Claude follows its permission rules and asks before operations that require approval."),
        .init(mode: .autoReview, title: "Auto", detail: "Claude reviews actions automatically and asks when its permission rules require you. Availability depends on the CLI, model and managed policies.")
    ]
    static func arguments(settings: AgentSettings, sessionID: String?) throws -> [String] {
        let mode = try permissionMode(settings)
        if let effort = settings.reasoningEffort, !["low", "medium", "high", "xhigh", "max"].contains(effort) {
            throw ProcessFailure.exited("Unsupported Claude effort level.")
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode]
        if let model = settings.model { args += ["--model", model] }
        if let effort = settings.reasoningEffort { args += ["--effort", effort] }
        // Optional-value flags must bind their argument even if a saved value starts with '-'.
        if let sessionID { args += ["--resume=\(sessionID)"] }
        return args
    }
    private static func permissionMode(_ settings: AgentSettings) throws -> String {
        switch settings.permissionMode ?? .autoReview {
        case .ask: return "manual"
        case .autoReview: return "auto"
        default: throw ProcessFailure.exited("This Claude adapter supports Manual and Auto. Claude plan mode is not an OS read-only sandbox; full access is not mapped.")
        }
    }
    static func validatePermissions(_ response: [String: Any], settings: AgentSettings) throws {
        let requested = try permissionMode(settings)
        guard let actual = response["current_permission_mode"] as? String else {
            if requested == "auto" {
                throw ProcessFailure.exited("This Claude CLI did not confirm Auto mode. Update Claude Code or choose Manual before sending.")
            }
            return
        }
        let expected = requested == "manual" ? "default" : requested
        guard (actual == "manual" ? "default" : actual) == expected else {
            throw ProcessFailure.exited("Claude did not enable the requested \(requested == "auto" ? "Auto" : "Manual") mode (reported \(AgentToolDetails.text(actual, limit: 80))). Check the model and CLI permission settings, or choose Manual before sending.")
        }
    }
    public func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings = AgentSettings(), images: [ImageAttachment] = []) async throws {
        guard !active else { throw ProcessFailure.exited("This thread already has a running turn.") }
        let arguments = try Self.arguments(settings: settings, sessionID: sessionID)
        guard let executable = executableOverride ?? Executables.find("claude") else { throw ProcessFailure.missing("claude") }
        let owner = UUID(), client = ClaudeConnection()
        generation = owner; active = true; ready = false; connection = client; remoteSession = sessionID; confirmedPermissionMode = nil
        streamedBlocks.removeAll(); thinkingBlocks.removeAll(); completedMessages.removeAll(); seenRequests.removeAll(); tools.removeAll()
        client.onObject = { [weak self] object in
            guard let self, self.generation == owner, self.active else { return }
            self.receive(object)
        }
        client.onDisconnect = { [weak self] detail in
            guard let self, self.generation == owner, self.active else { return }
            self.end(.failed(detail))
        }
        do {
            try client.start(executable: executable, directory: directory, arguments: arguments)
            let initialized = try await client.request(["subtype": "initialize"])
            guard active, generation == owner else { throw CancellationError() }
            try Task.checkCancellation()
            try Self.validatePermissions(initialized, settings: settings)
            confirmedPermissionMode = initialized["current_permission_mode"] as? String
            if let modelID = settings.model {
                let models = try Self.decodeModels(initialized)
                guard let model = models.first(where: { $0.model == modelID }) else { throw ProcessFailure.exited("The selected Claude model is unavailable. Refresh models and choose again.") }
                if let effort = settings.reasoningEffort, !model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) {
                    throw ProcessFailure.exited("The selected Claude model does not advertise this effort level.")
                }
            }
            var content: [[String: Any]] = []
            if !prompt.isEmpty { content.append(["type": "text", "text": prompt]) }
            content += images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.pngData.base64EncodedString()]] }
            ready = true
            try client.transport.write(["type": "user", "session_id": sessionID ?? "", "parent_tool_use_id": NSNull(),
                                        "message": ["role": "user", "content": content]])
        } catch {
            client.close()
            if generation == owner { active = false; connection = nil; invalidateRequests() }
            throw error
        }
    }
    public static func models(directory: String, executable: URL? = nil) async throws -> [AgentModel] {
        guard let executable = executable ?? Executables.find("claude") else { throw ProcessFailure.missing("claude") }
        let client = ClaudeConnection()
        defer { client.close() }
        // Catalog discovery must still work when Auto is unavailable.
        try client.start(executable: executable, directory: directory, arguments: arguments(settings: .init(permissionMode: .ask), sessionID: nil))
        return try decodeModels(await client.request(["subtype": "initialize"]))
    }
    static func decodeModels(_ response: [String: Any]) throws -> [AgentModel] {
        guard let values = response["models"] as? [[String: Any]], !values.isEmpty else {
            throw ProcessFailure.exited("This Claude CLI did not report a model catalog. CLI defaults remain available.")
        }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let id = value["value"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let efforts = value["supportsEffort"] as? Bool == true ? (value["supportedEffortLevels"] as? [String] ?? []).filter { ["low", "medium", "high", "xhigh", "max"].contains($0) } : []
            return AgentModel(model: id, displayName: value["displayName"] as? String ?? id,
                description: value["description"] as? String ?? "", hidden: false, isDefault: id == "default",
                defaultReasoningEffort: "", inputModalities: ["text", "image"],
                supportedReasoningEfforts: efforts.map { ReasoningOption(reasoningEffort: $0, description: "Claude CLI effort: \($0)") })
        }
    }
    private func receive(_ object: [String: Any]) {
        let type = object["type"] as? String
        if type == "control_request" { controlRequest(object); return }
        if type == "control_cancel_request", let id = object["request_id"] as? String { resolve(id); return }
        guard ready else { return }
        // Child-agent text must not replace the owning assistant response.
        if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return }
        if let session = object["session_id"] as? String, !session.isEmpty {
            if let expected = remoteSession, session != expected { return }
            if remoteSession == nil { remoteSession = session; onEvent?(.session(session)) }
        }
        switch type {
        case "stream_event": stream(object["event"] as? [String: Any] ?? [:])
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return }
            if let id = message["id"] as? String, !completedMessages.insert(id).inserted { return }
            for (index, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                switch block["type"] as? String {
                case "text": if !streamedBlocks.contains(index), let text = block["text"] as? String { onEvent?(.message(text)) }
                case "thinking": if !thinkingBlocks.contains(index), let text = block["thinking"] as? String { onEvent?(.reasoningDelta(text)) }
                case "tool_use": startTool(block)
                default: break
                }
            }
            streamedBlocks.removeAll(); thinkingBlocks.removeAll()
        case "user":
            let message = object["message"] as? [String: Any] ?? [:]
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, var tool = tools[id], tool.state == .running else { continue }
                tool.state = block["is_error"] as? Bool == true ? .failed : .completed
                // Tool bodies can contain secrets/binary data. Only display bounded text.
                if let text = block["content"] as? String { tool.detail = AgentToolDetails.text(text) }
                else if let blocks = block["content"] as? [[String: Any]] {
                    tool.detail = AgentToolDetails.text(blocks.prefix(16).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
                }
                tools[id] = tool; onEvent?(.toolActivity(tool))
            }
        case "result":
            if let denials = object["permission_denials"] as? [Any], !denials.isEmpty { onEvent?(.activity("Claude declined \(denials.count) operation(s) under its permission policy.")) }
            if object["is_error"] as? Bool == true {
                let detail = object["result"] as? String ?? (object["errors"] as? [String])?.joined(separator: "\n") ?? "Claude reported an error."
                end(.failed(AgentToolDetails.text(detail)))
            } else { end(.finished) }
        case "system":
            if object["subtype"] as? String == "init", let mode = object["permissionMode"] as? String {
                let normalized = mode == "manual" ? "default" : mode
                let previous = confirmedPermissionMode == "manual" ? "default" : confirmedPermissionMode
                if let previous, normalized != previous {
                    onEvent?(.interactionUnavailable("Claude changed its permission mode to \(AgentToolDetails.text(mode, limit: 80)). Its model and managed permission policies remain authoritative."))
                }
                confirmedPermissionMode = normalized
            }
            if object["subtype"] as? String == "compact_boundary" { onEvent?(.activity("Claude compacted the conversation.")) }
        case "rate_limit_event":
            if let usage = Self.decodeRateLimit(object["rate_limit_info"] as? [String: Any] ?? [:]) { onEvent?(.usage(usage)) }
        default: break
        }
    }
    /// Claude Code 2.1.302 SDK `rate_limit_event`: status/rateLimitType/utilization/resetsAt describe the
    /// limiting window. `unifiedWindows` is marked internal upstream, so it is read only when present.
    /// Utilization is a fraction of the window; values past 1 are possible. Absent fields stay unknown.
    static func decodeRateLimit(_ info: [String: Any], at date: Date = Date()) -> AgentUsage? {
        let known: [String: (name: String, minutes: Int?)] = [
            "five_hour": ("Session (5-hour)", 300), "seven_day": ("Weekly · all models", 10_080),
            "seven_day_opus": ("Weekly · Opus", 10_080), "seven_day_sonnet": ("Weekly · Sonnet", 10_080),
            "seven_day_overage_included": ("Weekly · including extra usage", 10_080), "overage": ("Extra usage", nil)]
        func window(_ type: String, utilization: Any?, resetsAt: Any?, limited: Bool) -> AgentUsageWindow {
            let percent = (utilization as? NSNumber).map { $0.doubleValue * 100 }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let reset = (resetsAt as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return AgentUsageWindow(id: type, usedPercent: percent, durationMinutes: known[type]?.minutes, resetsAt: reset,
                                    name: known[type]?.name ?? AgentToolDetails.text(type, limit: 60), isLimited: limited)
        }
        var windows: [String: AgentUsageWindow] = [:]
        for (type, value) in info["unifiedWindows"] as? [String: Any] ?? [:] {
            guard let value = value as? [String: Any] else { continue }
            windows[type] = window(type, utilization: value["utilization"], resetsAt: value["resetsAt"], limited: false)
        }
        if let type = info["rateLimitType"] as? String {
            let limited = info["status"] as? String == "rejected"
            var current = window(type, utilization: info["utilization"], resetsAt: info["resetsAt"], limited: limited)
            if let previous = windows[type] {
                current.usedPercent = current.usedPercent ?? previous.usedPercent
                current.resetsAt = current.resetsAt ?? previous.resetsAt
            }
            windows[type] = current
        }
        guard !windows.isEmpty else { return nil }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included", "overage"]
        let sorted = windows.values.sorted { (order.firstIndex(of: $0.id) ?? order.count, $0.id) < (order.firstIndex(of: $1.id) ?? order.count, $1.id) }
        return AgentUsage(buckets: [AgentUsageBucket(id: "claude", title: "Claude subscription", windows: sorted)], fetchedAt: date)
    }
    private func stream(_ event: [String: Any]) {
        if event["type"] as? String == "message_start" { streamedBlocks.removeAll(); thinkingBlocks.removeAll() }
        if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" { startTool(block) }
        guard let delta = event["delta"] as? [String: Any], let index = event["index"] as? Int else { return }
        if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
            streamedBlocks.insert(index); onEvent?(.textDelta(text))
        } else if delta["type"] as? String == "thinking_delta", let text = delta["thinking"] as? String {
            thinkingBlocks.insert(index); onEvent?(.reasoningDelta(text))
        }
    }
    private func startTool(_ block: [String: Any]) {
        guard let id = block["id"] as? String, tools[id] == nil else { return }
        let name = AgentToolDetails.text(block["name"] as? String ?? "Tool", limit: 128)
        let tool = ToolActivity(id: "\(generation):\(id)", server: "Claude", tool: name, state: .running)
        tools[id] = tool; onEvent?(.toolActivity(tool))
    }
    private func controlRequest(_ object: [String: Any]) {
        guard let id = object["request_id"] as? String, seenRequests.insert(id).inserted,
              let request = object["request"] as? [String: Any], let client = connection else { return }
        guard ready, request["subtype"] as? String == "can_use_tool", let name = request["tool_name"] as? String,
              let input = request["input"] as? [String: Any] else {
            try? client.reject(id: id, message: "Octo does not support this Claude control request.")
            onEvent?(.interactionUnavailable("Unsupported Claude control request declined.")); return
        }
        if name == "AskUserQuestion" {
            guard let interaction = Self.question(input) else {
                try? client.respond(id: id, response: ["behavior": "deny", "message": "Octo supports bounded single-choice questions only."])
                onEvent?(.interactionUnavailable("Claude question declined: this question format is unsupported.")); return
            }
            questions[interaction.id] = Question(requestID: id, input: input, interaction: interaction)
            onEvent?(.interaction(interaction)); return
        }
        let localID = UUID().uuidString, owner = generation
        approvals[id] = (localID, input)
        var details = [request["description"] as? String, request["decision_reason"] as? String, request["blocked_path"] as? String].compactMap { $0 }
        // These values are necessary to review the operation; never dump the full input.
        if name == "Bash", let command = input["command"] as? String { details.append(command) }
        if let path = input["file_path"] as? String { details.append(path) }
        let detail = AgentToolDetails.text(details.isEmpty ? "Claude requests permission to use \(name). This approval applies to this operation only." : details.joined(separator: "\n"))
        onEvent?(.approval(.init(id: localID, title: AgentToolDetails.text("\(name) approval", limit: 160), detail: detail, respond: { [weak self] allow in
            guard let self, self.active, self.generation == owner, let pending = self.approvals[id], let client = self.connection else { return }
            do {
                try client.respond(id: id, response: allow ? ["behavior": "allow", "updatedInput": pending.input] : ["behavior": "deny", "message": "The user declined this operation in Octo."])
                self.resolve(id)
            } catch { self.end(.failed(error.localizedDescription)) }
        })))
    }
    static func question(_ input: [String: Any]) -> AgentInteraction? {
        guard let questions = input["questions"] as? [[String: Any]], (1...4).contains(questions.count) else { return nil }
        var fields: [InteractionField] = [], seen = Set<String>()
        for question in questions {
            guard question["multiSelect"] == nil || question["multiSelect"] as? Bool == false,
                  let text = question["question"] as? String, !text.isEmpty, text.count <= 2048, seen.insert(text).inserted,
                  let options = question["options"] as? [[String: Any]], (2...8).contains(options.count) else { return nil }
            var labels = Set<String>(), choices: [InteractionOption] = []
            for option in options {
                guard let label = option["label"] as? String, !label.isEmpty, label.count <= 256, labels.insert(label).inserted else { return nil }
                choices.append(.init(id: label, label: label, detail: AgentToolDetails.text(option["description"] as? String ?? "", limit: 1024)))
            }
            var field = InteractionField(id: text, label: text, kind: .choice, required: true, options: choices, allowsOther: true)
            field.minLength = 1
            fields.append(field)
        }
        return AgentInteraction(title: "Claude has a question", detail: "Choose an answer or enter your own.", fields: fields, canDecline: true, cancellationDetail: "Cancel declines this question; it does not approve a tool.")
    }
    public func respond(to id: UUID, with response: AgentInteractionResponse) throws {
        guard active, let question = questions[id], let client = connection else { throw ProcessFailure.exited("This Claude question is no longer active.") }
        let reply: [String: Any]
        switch response {
        case .submit(let values):
            if let error = question.interaction.validationError(values) { throw ProcessFailure.exited(error) }
            var answers: [String: String] = [:]
            for (key, value) in values { if case .text(let text) = value { answers[key] = text } }
            var input = question.input; input["answers"] = answers
            reply = ["behavior": "allow", "updatedInput": input]
        case .decline, .cancel: reply = ["behavior": "deny", "message": "The user declined this question in Octo."]
        }
        try client.respond(id: question.requestID, response: reply); resolve(question.requestID)
    }
    private func resolve(_ requestID: String) {
        if let approval = approvals.removeValue(forKey: requestID) { onEvent?(.approvalResolved(approval.localID)) }
        for (id, question) in questions where question.requestID == requestID { questions.removeValue(forKey: id); onEvent?(.interactionResolved(id)) }
    }
    private func invalidateRequests() {
        let approvalIDs = approvals.values.map(\.localID), questionIDs = Array(questions.keys)
        approvals.removeAll(); questions.removeAll()
        approvalIDs.forEach { onEvent?(.approvalResolved($0)) }; questionIDs.forEach { onEvent?(.interactionResolved($0)) }
    }
    private func end(_ event: AgentEvent) {
        guard active else { return }
        active = false; ready = false; invalidateRequests()
        for (id, var tool) in tools where tool.state == .running {
            tool.state = .interrupted; tools[id] = tool; onEvent?(.toolActivity(tool))
        }
        let client = connection; connection = nil
        if case .finished = event { client?.finish() } else { client?.close() }
        onEvent?(event)
    }
    public func interrupt() async { end(.interrupted) }
    public func shutdown() { if active { end(.interrupted) }; connection?.close(); connection = nil; generation = UUID() }
}
