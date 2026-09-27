import Foundation

public struct WorkspaceProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var threads: [WorkspaceThread]
    public var isPinned = false
    public var isCollapsed = false
    public var orderedThreads: [WorkspaceThread] { threads.filter(\.isPinned) + threads.filter { !$0.isPinned } }

    private enum CodingKeys: String, CodingKey { case id, name, rootPath, threads, isPinned, isCollapsed }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        threads = try values.decode([WorkspaceThread].self, forKey: .threads)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isCollapsed = try values.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
    public init(id: UUID = UUID(), name: String, rootPath: String, threads: [WorkspaceThread] = []) {
        self.id = id; self.name = name; self.rootPath = rootPath; self.threads = threads
    }
}

public enum HarnessID: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Optional overrides; older threads continue using their provider's session defaults.
public struct AgentSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var permissionMode: AgentPermissionMode?
    public init(model: String? = nil, reasoningEffort: String? = nil, permissionMode: AgentPermissionMode? = nil) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.permissionMode = permissionMode
    }
}

/// Product intent only. Each adapter owns its mapping and supported subset.
public enum AgentPermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly, ask, autoReview, fullAccess
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .ask: return "Ask for approval"
        case .autoReview: return "Approve for me"
        case .fullAccess: return "Full access"
        }
    }
}

public struct WorkspaceThread: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var harness: HarnessID
    public var workingDirectory: String
    public var remoteSessionID: String?
    public var isPinned = false

    public var agentSettings = AgentSettings()

    private enum CodingKeys: String, CodingKey { case agentSettings, id, title, harness, workingDirectory, remoteSessionID, messages, createdAt, isPinned }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        agentSettings = try values.decodeIfPresent(AgentSettings.self, forKey: .agentSettings) ?? AgentSettings()
        title = try values.decode(String.self, forKey: .title)
        harness = try values.decode(HarnessID.self, forKey: .harness)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        remoteSessionID = try values.decodeIfPresent(String.self, forKey: .remoteSessionID)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
    public var messages: [ChatMessage]
    public var createdAt: Date
    public init(id: UUID = UUID(), title: String = "New thread", harness: HarnessID = .codex, workingDirectory: String) {
        self.id = id; self.title = title; self.harness = harness; self.workingDirectory = workingDirectory
        self.messages = []; self.createdAt = Date()
    }
}

public struct ImageAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let pngData: Data
    public init(id: UUID = UUID(), name: String = "Screenshot", pngData: Data) {
        self.id = id; self.name = name; self.pngData = pngData
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, activity, reasoning, error }
    public var id: UUID
    public var role: Role
    public var text: String
    public var attachments: [CodeAttachment]
    public var images: [ImageAttachment]
    public var createdAt: Date
    private enum CodingKeys: String, CodingKey { case id, role, text, attachments, images, createdAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decode([CodeAttachment].self, forKey: .attachments)
        images = try values.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
    public init(id: UUID = UUID(), role: Role, text: String, attachments: [CodeAttachment] = [], images: [ImageAttachment] = []) {
        self.id = id; self.role = role; self.text = text; self.attachments = attachments; self.images = images; self.createdAt = Date()
    }
}

/// Contiguous details share one disclosure; user messages, answers and errors stay visible.
public struct ChatMessageGroup: Identifiable {
    public var id: UUID { messages[0].id }
    public private(set) var messages: [ChatMessage]
    public var isDetails: Bool { messages[0].role == .activity || messages[0].role == .reasoning }
    public static func groups(_ messages: [ChatMessage]) -> [ChatMessageGroup] {
        var groups: [ChatMessageGroup] = []
        for message in messages {
            let detail = message.role == .activity || message.role == .reasoning
            if detail, groups.last?.isDetails == true {
                groups[groups.count - 1].messages.append(message)
            } else { groups.append(ChatMessageGroup(messages: [message])) }
        }
        return groups
    }
}

public struct WorkspaceArchive: Codable, Sendable {
    public var orderedProjects: [WorkspaceProject] { projects.filter(\.isPinned) + projects.filter { !$0.isPinned } }

    public mutating func removeThread(_ id: UUID, projectID: UUID) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[p].threads.removeAll { $0.id == id }
        if selectedThreadID == id { selectedThreadID = projects[p].orderedThreads.first?.id }
    }
    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        if selectedProjectID == id {
            selectedProjectID = orderedProjects.first?.id
            selectedThreadID = orderedProjects.first?.orderedThreads.first?.id
        }
    }
    public var schemaVersion = 1
    public var projects: [WorkspaceProject]
    public var selectedProjectID: UUID?
    public var selectedThreadID: UUID?
    public init(projects: [WorkspaceProject] = [], selectedProjectID: UUID? = nil, selectedThreadID: UUID? = nil) {
        self.projects = projects; self.selectedProjectID = selectedProjectID; self.selectedThreadID = selectedThreadID
    }
}
