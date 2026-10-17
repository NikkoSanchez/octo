import Foundation
import OctoCore

/// Each capability describes implemented adapter/UI support, not installed tools or account access.
public struct HarnessCapabilities: Equatable {
    public var toolActivity = false
    public var steering = false
    public var textToolResults = false
    public var structuredToolResults = false
    public var toolInventory = false
    public var forms = false
    public var toolQuestions = false
    public var appAccess = false
    public var urlElicitation = false
    public init() {}
    public static var claude: Self {
        var value = Self()
        value.toolActivity = true; value.textToolResults = true; value.toolQuestions = true
        return value
    }
    public static var codex: Self {
        var value = Self()
        value.steering = true
        value.toolActivity = true; value.textToolResults = true; value.structuredToolResults = true
        value.forms = true; value.toolQuestions = true; value.appAccess = true
        return value
    }
}

public enum InteractionValue: Equatable, Sendable {
    case text(String), boolean(Bool), number(Double)
}
public struct InteractionOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detail: String = ""
    public init(id: String, label: String, detail: String = "") { self.id = id; self.label = label; self.detail = detail }
}
public struct InteractionField: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case text, boolean, number, integer, choice }
    public var id: String
    public var label: String
    public var detail: String = ""
    public var kind: Kind
    public var required: Bool
    public var options: [InteractionOption] = []
    public var allowsOther = false
    public var minLength: Int? = nil
    public var maxLength: Int? = nil
    public var minimum: Double? = nil
    public var maximum: Double? = nil
    public init(id: String, label: String, detail: String = "", kind: Kind, required: Bool, options: [InteractionOption] = [], allowsOther: Bool = false) {
        self.id = id; self.label = label; self.detail = detail; self.kind = kind; self.required = required
        self.options = options; self.allowsOther = allowsOther
    }
}
public struct AgentInteraction: Identifiable, Equatable, Sendable {
    /// Unforgeable local identity; never a reusable provider request number.
    public var id: UUID
    public var title: String
    public var detail: String
    public var target: String?
    public var fields: [InteractionField]
    public var canDecline: Bool
    public var cancellationDetail: String
    public init(id: UUID = UUID(), title: String, detail: String, target: String? = nil, fields: [InteractionField], canDecline: Bool, cancellationDetail: String) {
        self.id = id; self.title = title; self.detail = detail; self.target = target; self.fields = fields
        self.canDecline = canDecline; self.cancellationDetail = cancellationDetail
    }
    public func validationError(_ values: [String: InteractionValue]) -> String? {
        guard Set(values.keys).isSubset(of: Set(fields.map(\.id))) else { return "Unexpected response field." }
        for field in fields {
            guard let value = values[field.id] else {
                if field.required { return "Choose or enter \(field.label)." }
                continue
            }
            switch (field.kind, value) {
            case (.text, .text(let text)), (.choice, .text(let text)):
                if field.kind == .choice && !field.allowsOther && !field.options.contains(where: { $0.id == text }) { return "Choose an advertised option for \(field.label)." }
                if text.unicodeScalars.count < (field.minLength ?? 0) || text.unicodeScalars.count > (field.maxLength ?? 4096) { return "Check the length of \(field.label)." }
            case (.boolean, .boolean): break
            case (.number, .number(let number)), (.integer, .number(let number)):
                if !number.isFinite || (field.kind == .integer && number.rounded() != number) || number < (field.minimum ?? -Double.greatestFiniteMagnitude) || number > (field.maximum ?? Double.greatestFiniteMagnitude) { return "Enter a valid number for \(field.label)." }
            default: return "Invalid value for \(field.label)."
            }
        }
        return nil
    }
}
public enum AgentInteractionResponse: Equatable, Sendable {
    case submit([String: InteractionValue]), decline, cancel
}
