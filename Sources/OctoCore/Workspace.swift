import Foundation

public struct WorkspaceProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var threads: [WorkspaceThread]
    public var isPinned = false
    public var isCollapsed = false
    /// The built-in home for conversations without a user-selected repository.
    public var isChatCollection = false
    public var orderedThreads: [WorkspaceThread] {
        // Threads are appended on creation. Reverse presentation only, retaining
        // archive order and keeping pins ahead of the remaining conversations.
        let newestFirst = threads.reversed()
        return newestFirst.filter(\.isPinned) + newestFirst.filter { !$0.isPinned }
    }

    private enum CodingKeys: String, CodingKey { case id, name, rootPath, threads, isPinned, isCollapsed, isChatCollection }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        threads = try values.decode([WorkspaceThread].self, forKey: .threads)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isCollapsed = try values.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        isChatCollection = try values.decodeIfPresent(Bool.self, forKey: .isChatCollection) ?? false
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
    public var isTitleManuallySet = false
    public var harness: HarnessID
    public var workingDirectory: String
    public var remoteSessionID: String?
    public var conversationUsage: ConversationUsage?
    public var lastCompaction: ContextCompaction?
    public var lastVisitedAt: Date?
    public var lastActivityAt: Date?
    public var unreadCompletedAt: Date?
    public var hasUnreadCompletion: Bool { unreadCompletedAt != nil }
    public var recentAt: Date {
        max(lastVisitedAt ?? createdAt, lastActivityAt ?? messages.last.map { $0.completedAt ?? $0.createdAt } ?? createdAt)
    }
    public var isPinned = false

    public var agentSettings = AgentSettings()

    private enum CodingKeys: String, CodingKey { case agentSettings, id, title, isTitleManuallySet, harness, workingDirectory, remoteSessionID, messages, createdAt, isPinned, conversationUsage, lastCompaction, lastVisitedAt, lastActivityAt, unreadCompletedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        agentSettings = try values.decodeIfPresent(AgentSettings.self, forKey: .agentSettings) ?? AgentSettings()
        title = try values.decode(String.self, forKey: .title)
        isTitleManuallySet = try values.decodeIfPresent(Bool.self, forKey: .isTitleManuallySet) ?? false
        harness = try values.decode(HarnessID.self, forKey: .harness)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        remoteSessionID = try values.decodeIfPresent(String.self, forKey: .remoteSessionID)
        conversationUsage = try values.decodeIfPresent(ConversationUsage.self, forKey: .conversationUsage)
        lastCompaction = try values.decodeIfPresent(ContextCompaction.self, forKey: .lastCompaction)
        lastVisitedAt = try values.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
        lastActivityAt = try values.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        unreadCompletedAt = try values.decodeIfPresent(Date.self, forKey: .unreadCompletedAt)
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
    public var completedAt: Date?
    /// Recorded on the initiating user message. Absent on legacy conversations.
    public var toolActivity: ToolActivity?
    public var work: TurnWork?
    private enum CodingKeys: String, CodingKey { case id, role, text, attachments, images, createdAt, completedAt, work, toolActivity }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decode([CodeAttachment].self, forKey: .attachments)
        images = try values.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        work = try values.decodeIfPresent(TurnWork.self, forKey: .work)
        toolActivity = try values.decodeIfPresent(ToolActivity.self, forKey: .toolActivity)
    }
    public init(id: UUID = UUID(), role: Role, text: String, attachments: [CodeAttachment] = [], images: [ImageAttachment] = []) {
        self.id = id; self.role = role; self.text = text; self.attachments = attachments; self.images = images; self.createdAt = Date()
    }
}

public struct TurnWork: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, stopped, failed, interrupted }
    public var startedAt: Date
    public var elapsed: TimeInterval?
    public var outcome: Outcome?
    public init(startedAt: Date = Date()) { self.startedAt = startedAt }
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(min(31_536_000, max(0, interval.isFinite ? interval : 0)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
    public var label: String {
        let prefix: String
        switch outcome {
        case .completed: prefix = "Worked for"
        case .stopped: prefix = "Stopped after"
        case .failed: prefix = "Failed after"
        case .interrupted: prefix = "Interrupted after"
        case nil: return "Interrupted"
        }
        guard let elapsed else { return outcome == .interrupted ? "Interrupted" : prefix }
        return "\(prefix) \(Self.duration(elapsed))"
    }
}

/// A user message starts a turn; imported leading responses form their own group.
public struct ChatTurn: Identifiable {
    public var id: UUID { messages[0].id }
    public var messages: [ChatMessage]
    public var user: ChatMessage? { messages.first?.role == .user ? messages.first : nil }
    public var details: [ChatMessage] { messages.filter { $0.role == .reasoning || $0.role == .activity } }
    public var responses: [ChatMessage] { messages.filter { $0.role == .assistant || $0.role == .error } }
    public static func turns(_ messages: [ChatMessage]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for message in messages {
            if message.role == .user || turns.isEmpty { turns.append(ChatTurn(messages: [message])) }
            else { turns[turns.count - 1].messages.append(message) }
        }
        return turns
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
    public var searchableThreads: [RecentThread] {
        ((chats.map { [$0] } ?? []) + orderedProjects).flatMap { project in
            project.orderedThreads.map { RecentThread(project: project, thread: $0) }
        }
    }
    /// Recent conversations span projects; empty composers remain in their project.
    public var recentThreads: [RecentThread] {
        Array(projects.flatMap { project in
            project.threads.filter { !$0.messages.isEmpty }.map { RecentThread(project: project, thread: $0) }
        }.sorted {
            if $0.thread.recentAt != $1.thread.recentAt { return $0.thread.recentAt > $1.thread.recentAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(8))
    }
    public var chats: WorkspaceProject? { projects.first(where: \.isChatCollection) }
    public var orderedProjects: [WorkspaceProject] {
        let repositories = projects.filter { !$0.isChatCollection }
        return repositories.filter(\.isPinned) + repositories.filter { !$0.isPinned }
    }

    public mutating func removeThread(_ id: UUID, projectID: UUID) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[p].threads.removeAll { $0.id == id }
        if selectedThreadID == id { selectedThreadID = projects[p].orderedThreads.first?.id }
    }
    public mutating func removeProject(_ id: UUID) {
        guard projects.first(where: { $0.id == id })?.isChatCollection != true else { return }
        projects.removeAll { $0.id == id }
        if selectedProjectID == id {
            let next = orderedProjects.first ?? chats
            selectedProjectID = next?.id
            selectedThreadID = next?.orderedThreads.first?.id
        }
    }
    // Optional fields preserve decoding of archives created before draft defaults.
    public var lastHarness: HarnessID?
    public var rememberedAgentSettings: [String: AgentSettings]?
    // Missing values preserve expanded sections in older archives.
    public var projectsSectionCollapsed: Bool?
    public var recentSectionCollapsed: Bool?
    public var schemaVersion = 1
    public var projects: [WorkspaceProject]
    public var selectedProjectID: UUID?
    public var selectedThreadID: UUID?
    public init(projects: [WorkspaceProject] = [], selectedProjectID: UUID? = nil, selectedThreadID: UUID? = nil) {
        self.projects = projects; self.selectedProjectID = selectedProjectID; self.selectedThreadID = selectedThreadID
    }
}

public struct RecentThread: Identifiable {
    public var id: UUID { thread.id }
    public let project: WorkspaceProject
    public let thread: WorkspaceThread
}
