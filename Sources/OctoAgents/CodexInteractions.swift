import Foundation
import CoreFoundation
import OctoCore

/// Wire decoding for app-server v2 (generated with 0.158.0-alpha.2.1).
/// Deliberately a strict subset: unknown constraints cannot silently weaken a form.
struct CodexInteraction {
    let request: AgentInteraction
    let questions: Bool
    let persistence: [String: [String: String]]
    let metadataScopeField: String?

    static func decode(_ p: [String: Any], questions: Bool) throws -> Self {
        func invalid(_ reason: String) -> ProcessFailure { .exited("Unsupported Codex interaction: \(reason)") }
        var fields: [InteractionField] = []
        var persistence: [String: [String: String]] = [:]
        let message: String
        var target: String?
        var metadataScopeField: String?
        if questions {
            guard let items = p["questions"] as? [[String: Any]], !items.isEmpty, items.count <= 16 else { throw invalid("invalid questions") }
            message = "Answer the provider’s questions explicitly."
            for item in items {
                guard let id = item["id"] as? String, !id.isEmpty, let header = item["header"] as? String,
                      let question = item["question"] as? String, item["isSecret"] as? Bool != true else { throw invalid("invalid or secret question; use the CLI’s authentication workflow") }
                for flag in ["isSecret", "isOther"] {
                    if let raw = item[flag], !(raw is Bool) { throw invalid("invalid question flags") }
                }
                var field = InteractionField(id: id, label: header, detail: question, kind: .text, required: true)
                if let options = item["options"], !(options is NSNull) {
                    guard let options = options as? [[String: Any]], !options.isEmpty, options.count <= 32 else { throw invalid("invalid question choices") }
                    field.kind = .choice
                    field.options = try options.map {
                        guard let label = $0["label"] as? String, let detail = $0["description"] as? String else { throw invalid("invalid question option") }
                        return InteractionOption(id: label, label: label, detail: detail)
                    }
                    field.allowsOther = item["isOther"] as? Bool == true
                }
                fields.append(field)
            }
        } else {
            guard ["form", "openai/form", "openaiForm"].contains(p["mode"] as? String ?? ""),
                  let text = p["message"] as? String, let schema = p["requestedSchema"] as? [String: Any],
                  schema["type"] as? String == "object", let properties = schema["properties"] as? [String: [String: Any]], properties.count <= 16 else { throw invalid("only bounded forms are supported; URL/device verification must use the owning CLI") }
            message = text
            try checkKeys(schema, allowed: ["type", "properties", "required", "$schema", "additionalProperties"])
            if let extra = schema["additionalProperties"], !(extra is NSNull), extra as? Bool != false { throw invalid("additional properties") }
            let required: [String]
            if let raw = schema["required"], !(raw is NSNull) {
                guard let value = raw as? [String] else { throw invalid("required fields") }; required = value
            } else { required = [] }
            guard Set(required).isSubset(of: Set(properties.keys)), Set(required).count == required.count else { throw invalid("unknown or repeated required field") }
            if let meta = p["_meta"] as? [String: Any] {
                let nested = [meta["target"] as? [String: Any], meta["tool_params"] as? [String: Any]].compactMap { $0 }
                target = ([meta] + nested).flatMap { data in ["app_name", "appName", "app", "name"].compactMap { data[$0] as? String } }.first
            }
            if target == nil, message.hasPrefix("Allow ChatGPT to use "), message.hasSuffix("?") {
                target = String(message.dropFirst("Allow ChatGPT to use ".count).dropLast())
            }
            // Message remains visible even if metadata does not identify the app.
            for key in properties.keys.sorted() {
                let data = properties[key]!
                try checkKeys(data, allowed: ["type", "title", "description", "default", "enum", "enumNames", "oneOf", "minLength", "maxLength", "minimum", "maximum"])
                for name in ["title", "description"] {
                    if let raw = data[name], !(raw is NSNull), !(raw is String) { throw invalid("invalid field label") }
                }
                guard let type = data["type"] as? String else { throw invalid("field type") }
                var field = InteractionField(id: key, label: data["title"] as? String ?? key, detail: data["description"] as? String ?? "", kind: .text, required: required.contains(key))
                switch type {
                case "string":
                    if let raw = data["oneOf"], !(raw is NSNull) {
                        guard data["enum"] == nil || data["enum"] is NSNull, let choices = raw as? [[String: Any]] else { throw invalid("conflicting choices") }
                        field.options = try choices.map {
                            try checkKeys($0, allowed: ["const", "title"])
                            guard let value = $0["const"] as? String else { throw invalid("choice value") }
                            return InteractionOption(id: value, label: $0["title"] as? String ?? value)
                        }
                        field.kind = .choice
                    } else if let raw = data["enum"], !(raw is NSNull) {
                        guard let choices = raw as? [String] else { throw invalid("string enum") }
                        var labels = choices
                        if let names = data["enumNames"], !(names is NSNull) {
                            guard let names = names as? [String], names.count == choices.count else { throw invalid("enum labels") }; labels = names
                        }
                        field.options = zip(choices, labels).map { InteractionOption(id: $0.0, label: $0.1) }; field.kind = .choice
                    }
                    field.minLength = try bound(data["minLength"])
                    field.maxLength = try bound(data["maxLength"])
                    if let min = field.minLength, let max = field.maxLength, min > max { throw invalid("length bounds") }
                    // Only exact, provider-advertised values affect the extension metadata.
                    for option in field.options where ["approval", "persist"].contains(key) && ["session", "always"].contains(option.id) {
                        persistence[key, default: [:]][option.id] = option.id
                    }
                case "boolean":
                    field.kind = .boolean
                    if key == "always" { persistence[key] = ["true": "always"] }
                    if key == "session" { persistence[key] = ["true": "session"] }
                case "number", "integer": field.kind = type == "integer" ? .integer : .number
                default: throw invalid("field type \(type)")
                }
                if type != "string", ["enum", "enumNames", "oneOf", "minLength", "maxLength"].contains(where: { data[$0] != nil && !(data[$0] is NSNull) }) { throw invalid("constraints on non-string field") }
                for name in ["minimum", "maximum"] {
                    if let raw = data[name], !(raw is NSNull) {
                        guard ["number", "integer"].contains(type), let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("numeric constraint") }
                        if name == "minimum" { field.minimum = number.doubleValue } else { field.maximum = number.doubleValue }
                    }
                }
                if let min = field.minimum, let max = field.maximum, min > max { throw invalid("numeric bounds") }
                fields.append(field)
            }
        }
        // The bundled Computer Use policy advertises duration in metadata, with an
        // empty form. This is a separate protocol extension, not a schema default.
        // Keep it narrowly identified so generic forms cannot acquire broader consent.
        if !questions, fields.isEmpty, p["mode"] as? String == "form",
           let meta = p["_meta"] as? [String: Any],
           meta["codex_approval_kind"] as? String == "mcp_tool_call",
           meta["connector_id"] as? String == "computer-use",
           let params = meta["tool_params"] as? [String: Any],
           let app = params["app"] as? String, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let tool = meta["tool_name"] as? String, !tool.isEmpty,
           let scopes = meta["persist"] as? [String], !scopes.isEmpty,
           scopes.count <= 2, Set(scopes).count == scopes.count,
           scopes.allSatisfy({ ["session", "always"].contains($0) }) {
            let key = "octo.accessDuration"
            metadataScopeField = key
            target = app
            if let display = meta["tool_params_display"] as? [[String: Any]],
               let name = display.first(where: { $0["name"] as? String == "app" })?["value"] as? String,
               !name.isEmpty { target = "\(name) (\(app))" }
            var options = [InteractionOption(id: "once", label: "Allow once", detail: "Approve only this request.")]
            if scopes.contains("session") {
                options.append(InteractionOption(id: "session", label: "Allow for this chat session", detail: "Let Computer Use access this app for the current provider session."))
            }
            if scopes.contains("always") {
                options.append(InteractionOption(id: "always", label: "Always allow this app", detail: "The provider remembers this permission beyond the current chat session."))
            }
            fields.append(InteractionField(id: key, label: "App access", detail: "Choose how long to allow access to this app.", kind: .choice, required: true, options: options))
            persistence[key] = Dictionary(uniqueKeysWithValues: scopes.map { ($0, $0) })
        }
        guard Set(fields.map(\.id)).count == fields.count else { throw invalid("repeated field ID") }
        for field in fields {
            guard !field.id.isEmpty, field.id.count <= 256, field.label.count <= 1024, field.detail.count <= 8192,
                  field.kind != .choice || (!field.options.isEmpty && field.options.count <= 32),
                  Set(field.options.map(\.id)).count == field.options.count,
                  field.options.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 1024 && $0.label.count <= 1024 && $0.detail.count <= 4096 }) else { throw invalid("field/choice bounds or duplicates") }
        }
        guard message.count <= 16384, (target?.count ?? 0) <= 1024 else { throw invalid("request too large") }
        return Self(request: AgentInteraction(id: UUID(), title: questions ? "Input requested" : "Access / information requested", detail: message, target: target, fields: fields, canDecline: !questions,
            cancellationDetail: questions ? "Cancel sends no answers; it does not approve a choice." : "Decline refuses this request. Cancel dismisses it without consent."), questions: questions, persistence: persistence, metadataScopeField: metadataScopeField)
    }
    func response(_ response: AgentInteractionResponse) throws -> [String: Any] {
        switch response {
        case .cancel: return questions ? ["answers": [:]] : ["action": "cancel", "content": NSNull()]
        case .decline:
            guard !questions else { throw ProcessFailure.exited("Decline is unavailable for this request.") }
            return ["action": "decline", "content": NSNull()]
        case .submit(let values):
            if let error = request.validationError(values) { throw ProcessFailure.exited(error) }
            var content: [String: Any] = [:], scopes = Set<String>()
            for (key, value) in values {
                let lookup: String
                switch value {
                case .text(let text): content[key] = questions ? ["answers": [text]] : text; lookup = text
                case .boolean(let bool): content[key] = bool; lookup = String(bool)
                case .number(let number): content[key] = number; lookup = ""
                }
                if let scope = persistence[key]?[lookup] { scopes.insert(scope) }
            }
            if let metadataScopeField { content.removeValue(forKey: metadataScopeField) }
            guard scopes.count <= 1 else { throw ProcessFailure.exited("Conflicting access durations; choose a single duration.") }
            if questions { return ["answers": content] }
            var result: [String: Any] = ["action": "accept", "content": content]
            if let scope = scopes.first { result["_meta"] = ["persist": scope] }
            return result
        }
    }
    private static func checkKeys(_ data: [String: Any], allowed: Set<String>) throws {
        guard Set(data.keys).isSubset(of: allowed) else { throw ProcessFailure.exited("Unsupported form constraints. Use the owning CLI workflow.") }
    }
    private static func bound(_ raw: Any?) throws -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue >= 0, value.doubleValue <= 4096, value.doubleValue.rounded() == value.doubleValue else { throw ProcessFailure.exited("Unsupported length bound.") }
        return value.intValue
    }
}
