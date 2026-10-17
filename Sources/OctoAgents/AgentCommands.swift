import Foundation
import OctoCore

/// User-invocable entries advertised by the provider, never inferred from skill files.
public struct AgentCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let argumentHint: String
    public let skillPath: String?
    public init(name: String, description: String = "", argumentHint: String = "", skillPath: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.skillPath = skillPath
    }
}

@MainActor public extension HarnessRegistry {
    static func commands(_ harness: HarnessID, directory: String, codexExecutable: URL? = nil) async throws -> [AgentCommand] {
        switch harness {
        case .claude: return try await ClaudeHarness.commands(directory: directory)
        case .codex: return try await CodexHarness.commands(directory: directory, executable: codexExecutable)
        }
    }
}

@MainActor public extension CodexHarness {
    static func commands(directory: String, executable: URL? = nil) async throws -> [AgentCommand] {
        guard let executable = executable ?? CodexExecutable.resolve() else { throw ProcessFailure.missing("codex") }
        let connection = RPCConnection()
        defer { connection.close() }
        try connection.start(executable: executable, directory: directory)
        _ = try await connection.request("initialize", ["clientInfo": ["name": "octo", "title": "Octo", "version": "0.1.0"]])
        try connection.notify("initialized")
        return try decodeCommands(await connection.request("skills/list", ["cwds": [directory], "forceReload": true]), directory: directory)
    }
    internal static func decodeCommands(_ response: [String: Any], directory: String) throws -> [AgentCommand] {
        guard let entries = response["data"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["cwd"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } == URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path }),
              let skills = entry["skills"] as? [[String: Any]] else {
            throw ProcessFailure.exited("Codex did not report a skill catalog for this checkout.")
        }
        var seen = Set<String>()
        return skills.prefix(2000).compactMap { skill in
            guard skill["enabled"] as? Bool == true, let name = skill["name"] as? String, name.count <= 200,
                  name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\-]*$"#, options: .regularExpression) != nil,
                  let path = skill["path"] as? String, path.hasPrefix("/"), !path.contains("\n"), seen.insert(name).inserted else { return nil }
            let interface = skill["interface"] as? [String: Any]
            return AgentCommand(name: name, description: AgentToolDetails.text(interface?["shortDescription"] as? String ?? skill["shortDescription"] as? String ?? skill["description"] as? String ?? "", limit: 1024), skillPath: path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    internal static func commandName(in prompt: String) -> String? {
        guard prompt.first == "/" else { return nil }
        return String(prompt.dropFirst().prefix { !$0.isWhitespace })
    }
    internal static func commandInput(prompt: String, commands: [AgentCommand]) -> [[String: Any]] {
        guard let name = commandName(in: prompt), let command = commands.first(where: { $0.name == name }), let path = command.skillPath else {
            return prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
        }
        // The user's explicit slash invocation becomes native provider skill input.
        // Keep arguments and attached context intact; skill contents are never copied by Octo.
        let text = "$" + name + prompt.dropFirst(name.count + 1)
        return [["type": "text", "text": text], ["type": "skill", "name": name, "path": path]]
    }
}

@MainActor public extension ClaudeHarness {
    static func commands(directory: String, executable: URL? = nil) async throws -> [AgentCommand] {
        guard let executable = executable ?? Executables.find("claude") else { throw ProcessFailure.missing("claude") }
        let client = ClaudeConnection()
        defer { client.close() }
        try client.start(executable: executable, directory: directory,
                         arguments: arguments(settings: .init(permissionMode: .ask), sessionID: nil))
        return try decodeCommands(await client.request(["subtype": "initialize"]))
    }

    internal static func decodeCommands(_ response: [String: Any]) throws -> [AgentCommand] {
        guard let values = response["commands"] as? [[String: Any]] else {
            throw ProcessFailure.exited("This Claude CLI does not report a command catalog. You can still type a known /command explicitly.")
        }
        var seen = Set<String>()
        return values.prefix(2000).compactMap { value in
            guard let name = value["name"] as? String, name.count <= 200,
                  name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\-]*$"#, options: .regularExpression) != nil,
                  seen.insert(name).inserted else { return nil }
            return AgentCommand(name: name, description: AgentToolDetails.text(value["description"] as? String ?? "", limit: 1024),
                                argumentHint: AgentToolDetails.text(value["argumentHint"] as? String ?? "", limit: 200))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Read-only CLI status. Credentials stay inside the installed CLI and its Keychain/config.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let method: String
    public var title: String { loggedIn ? "Signed in · \(method)" : "Signed out" }
}
public enum ClaudeCLI {
    public static var loginArguments: [String] { ["auth", "login"] }
    public static func authStatus(executable: URL? = nil) async throws -> ClaudeAuthStatus {
        guard let executable = executable ?? Executables.find("claude") else { throw ProcessFailure.missing("claude") }
        let result = try await ProcessRunner.run(executable, arguments: ["auth", "status", "--json"],
                                                directory: FileManager.default.homeDirectoryForCurrentUser, outputLimit: 64_000)
        // Signed-out status exits 1, with a valid JSON report.
        guard result.status == 0 || result.status == 1 else { throw ProcessFailure.exited("Claude authentication status is unavailable. Check the installed CLI.") }
        return try decodeAuthStatus(result.output)
    }
    internal static func decodeAuthStatus(_ data: Data) throws -> ClaudeAuthStatus {
        struct Report: Decodable { let loggedIn: Bool; let authMethod: String }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ProcessFailure.exited("Claude did not return a supported authentication status. Run claude auth status in your terminal.")
        }
        return ClaudeAuthStatus(loggedIn: report.loggedIn, method: AgentToolDetails.text(report.authMethod, limit: 80))
    }
}
