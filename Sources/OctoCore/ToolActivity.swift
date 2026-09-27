import Foundation

public struct ToolActivity: Identifiable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, failed, interrupted }
    public var id: String
    public var server: String
    public var tool: String
    public var state: State
    public var detail: String
    public init(id: String, server: String, tool: String, state: State, detail: String = "") {
        self.id = id; self.server = server; self.tool = tool; self.state = state; self.detail = detail
    }
    public var text: String { "\(server) / \(tool) · \(state.rawValue.capitalized)" + (detail.isEmpty ? "" : "\n\(detail)") }
}
