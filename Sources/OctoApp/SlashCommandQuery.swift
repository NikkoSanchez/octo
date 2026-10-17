import Foundation
import OctoAgents

enum SlashCommandQuery {
    static func prefix(in text: String) -> String? {
        guard text.first == "/", !text.contains(where: { $0.isWhitespace }) else { return nil }
        return String(text.dropFirst())
    }
    static func matches(_ commands: [AgentCommand], text: String) -> [AgentCommand] {
        guard let prefix = prefix(in: text) else { return [] }
        return commands.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
    }
    static func insertion(_ command: AgentCommand) -> String { "/\(command.name) " }
}
