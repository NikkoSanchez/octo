import SwiftUI
import OctoAgents

/// Only neutral models and generic actions. No provider JSON, policy inference or consent defaults.
struct InteractionCard: View {
    let request: AgentInteraction
    let respond: (AgentInteractionResponse) -> String?
    @Environment(\.octoTheme) private var theme
    @State private var values: [String: InteractionValue] = [:]
    @State private var rawInputs: [String: String] = [:]
    private enum Choice: Hashable { case unset, advertised(String), other }
    @State private var other = Set<String>()
    @State private var error: String?
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised").font(.headline)
            if let target = request.target { Text("Target app: \(target)").fontWeight(.semibold) }
            Text(request.detail).textSelection(.enabled)
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.label + (field.required ? " (required)" : " (optional)")).fontWeight(.medium)
                    if !field.detail.isEmpty { Text(field.detail).font(.caption).foregroundStyle(theme.secondary) }
                    fieldView(field)
                }
            }
            Text(request.cancellationDetail).font(.caption).foregroundStyle(theme.secondary)
            if let error { Text(error).foregroundStyle(theme.red).accessibilityLabel("Response error: \(error)") }
            HStack {
                Button("Cancel") { send(.cancel) }
                if request.canDecline { Button("Decline") { send(.decline) } }
                Spacer()
                Button("Submit response") { send(.submit(values)) }
                    .disabled(request.validationError(values) != nil)
            }.disabled(submitted)
        }.font(.system(size: 13)).padding(12)
            .background(theme.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func fieldView(_ field: InteractionField) -> some View {
        switch field.kind {
        case .boolean:
            Picker(field.label, selection: Binding(get: {
                if case .boolean(let value) = values[field.id] { return value ? "true" : "false" }; return ""
            }, set: { values[field.id] = $0.isEmpty ? nil : .boolean($0 == "true") })) {
                Text("Choose…").tag(""); Text("Yes / true").tag("true"); Text("No / false").tag("false")
            }.labelsHidden()
        case .choice:
            Picker(field.label, selection: Binding(get: {
                if other.contains(field.id) { return Choice.other }
                if case .text(let value) = values[field.id] { return Choice.advertised(value) }; return Choice.unset
            }, set: {
                switch $0 {
                case .other: other.insert(field.id); values[field.id] = nil; rawInputs[field.id] = ""
                case .unset: other.remove(field.id); values[field.id] = nil
                case .advertised(let value): other.remove(field.id); values[field.id] = .text(value)
                }
            })) {
                Text("Choose…").tag(Choice.unset)
                ForEach(field.options) { option in Text(option.label).tag(Choice.advertised(option.id)) }
                if field.allowsOther { Text("Write an answer…").tag(Choice.other) }
            }.labelsHidden()
            if other.contains(field.id) { textInput(field) }
            if case .text(let value) = values[field.id], let selected = field.options.first(where: { $0.id == value }) {
                Text("Selected: \(selected.label) [\(selected.id)]").font(.caption).textSelection(.enabled)
                if !selected.detail.isEmpty { Text(selected.detail).font(.caption) }
            }
        case .text, .number, .integer: textInput(field)
        }
    }
    private func textInput(_ field: InteractionField) -> some View {
        TextField(field.label, text: Binding(get: {
            rawInputs[field.id] ?? ""
        }, set: { value in
            rawInputs[field.id] = value
            if value.isEmpty && !field.required { values[field.id] = nil }
            else if (field.kind == .number || field.kind == .integer), let number = Double(value) { values[field.id] = .number(number) }
            else { values[field.id] = .text(value) }
        })).textFieldStyle(.roundedBorder)
    }
    private func send(_ response: AgentInteractionResponse) {
        guard !submitted else { return }
        if case .submit(let values) = response, let validation = request.validationError(values) { error = validation; return }
        error = respond(response)
        submitted = error == nil
    }
}
