import Foundation

enum CodexHostKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case ssh

    var id: String { rawValue }
}

struct CodexHost: Codable, Hashable, Identifiable, Sendable {
    static let localID = "local"
    static let local = CodexHost(
        id: localID,
        name: "本机",
        kind: .local,
        sshAlias: nil,
        isEnabled: true,
        maxConcurrentExecutions: 2
    )

    let id: String
    var name: String
    var kind: CodexHostKind
    var sshAlias: String?
    var isEnabled: Bool
    private var storedMaxConcurrentExecutions: Int

    var maxConcurrentExecutions: Int {
        get { storedMaxConcurrentExecutions }
        set { storedMaxConcurrentExecutions = max(1, newValue) }
    }

    init(
        id: String,
        name: String,
        kind: CodexHostKind,
        sshAlias: String? = nil,
        isEnabled: Bool = true,
        maxConcurrentExecutions: Int = 1
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sshAlias = sshAlias
        self.isEnabled = isEnabled
        storedMaxConcurrentExecutions = max(1, maxConcurrentExecutions)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case sshAlias
        case isEnabled
        case maxConcurrentExecutions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(CodexHostKind.self, forKey: .kind)
        sshAlias = try container.decodeIfPresent(String.self, forKey: .sshAlias)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        storedMaxConcurrentExecutions = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .maxConcurrentExecutions) ?? 1
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(sshAlias, forKey: .sshAlias)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(maxConcurrentExecutions, forKey: .maxConcurrentExecutions)
    }
}

struct ManualProjectReference: Codable, Hashable, Sendable {
    var hostID: String
    var path: String

    init(hostID: String = CodexHost.localID, path: String) {
        self.hostID = hostID
        self.path = path
    }
}

enum TaskSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case issue
    case developmentPlan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .issue: "Issue"
        case .developmentPlan: "开发计划"
        }
    }

    var symbol: String {
        switch self {
        case .issue: "exclamationmark.circle"
        case .developmentPlan: "doc.text"
        }
    }
}

enum TaskStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox
    case planning
    case awaitingApproval
    case executing
    case completed
    case needsAttention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "待办"
        case .planning: "规划中"
        case .awaitingApproval: "待确认"
        case .executing: "执行中"
        case .completed: "已完成"
        case .needsAttention: "需要处理"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .planning: "sparkles"
        case .awaitingApproval: "checkmark.seal"
        case .executing: "hammer"
        case .completed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var allowsManualDrop: Bool {
        switch self {
        case .planning, .executing: false
        default: true
        }
    }

    var isActive: Bool {
        self == .planning || self == .executing
    }
}

struct ProjectRecord: Codable, Hashable, Identifiable, Sendable {
    let hostID: String
    var name: String
    var path: String
    var observedWorkingDirectories: [String]
    var manualPaths: [String]
    var latestActivityAt: Date?
    var threadCount: Int
    var activeThreadCount: Int
    var isGitRepository: Bool
    var existsOnDisk: Bool
    var isManual: Bool

    var id: String {
        Self.identifier(hostID: hostID, path: path)
    }

    init(
        hostID: String = CodexHost.localID,
        name: String,
        path: String,
        observedWorkingDirectories: [String] = [],
        manualPaths: [String] = [],
        latestActivityAt: Date? = nil,
        threadCount: Int = 0,
        activeThreadCount: Int = 0,
        isGitRepository: Bool = false,
        existsOnDisk: Bool = true,
        isManual: Bool = false
    ) {
        self.hostID = hostID
        self.name = name
        self.path = path
        self.observedWorkingDirectories = observedWorkingDirectories
        self.manualPaths = manualPaths
        self.latestActivityAt = latestActivityAt
        self.threadCount = threadCount
        self.activeThreadCount = activeThreadCount
        self.isGitRepository = isGitRepository
        self.existsOnDisk = existsOnDisk
        self.isManual = isManual
    }

    init(
        id _: String,
        name: String,
        path: String,
        observedWorkingDirectories: [String] = [],
        manualPaths: [String] = [],
        latestActivityAt: Date? = nil,
        threadCount: Int = 0,
        activeThreadCount: Int = 0,
        isGitRepository: Bool = false,
        existsOnDisk: Bool = true,
        isManual: Bool = false
    ) {
        self.init(
            hostID: CodexHost.localID,
            name: name,
            path: path,
            observedWorkingDirectories: observedWorkingDirectories,
            manualPaths: manualPaths,
            latestActivityAt: latestActivityAt,
            threadCount: threadCount,
            activeThreadCount: activeThreadCount,
            isGitRepository: isGitRepository,
            existsOnDisk: existsOnDisk,
            isManual: isManual
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hostID
        case name
        case path
        case observedWorkingDirectories
        case manualPaths
        case latestActivityAt
        case threadCount
        case activeThreadCount
        case isGitRepository
        case existsOnDisk
        case isManual
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            ?? CodexHost.localID
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        observedWorkingDirectories = try container.decode(
            [String].self,
            forKey: .observedWorkingDirectories
        )
        manualPaths = try container.decodeIfPresent([String].self, forKey: .manualPaths) ?? []
        latestActivityAt = try container.decodeIfPresent(Date.self, forKey: .latestActivityAt)
        threadCount = try container.decode(Int.self, forKey: .threadCount)
        activeThreadCount = try container.decode(Int.self, forKey: .activeThreadCount)
        isGitRepository = try container.decode(Bool.self, forKey: .isGitRepository)
        existsOnDisk = try container.decode(Bool.self, forKey: .existsOnDisk)
        isManual = try container.decode(Bool.self, forKey: .isManual)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(observedWorkingDirectories, forKey: .observedWorkingDirectories)
        try container.encode(manualPaths, forKey: .manualPaths)
        try container.encodeIfPresent(latestActivityAt, forKey: .latestActivityAt)
        try container.encode(threadCount, forKey: .threadCount)
        try container.encode(activeThreadCount, forKey: .activeThreadCount)
        try container.encode(isGitRepository, forKey: .isGitRepository)
        try container.encode(existsOnDisk, forKey: .existsOnDisk)
        try container.encode(isManual, forKey: .isManual)
    }

    private static func identifier(hostID: String, path: String) -> String {
        guard hostID != CodexHost.localID else { return path }
        return "host:\(hostID.utf8.count):\(hostID):\(path)"
    }
}

struct TaskLogEntry: Codable, Hashable, Identifiable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case success
        case warning
        case error
    }

    let id: UUID
    let date: Date
    let level: Level
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

struct CodexPlanStep: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case completed
    }

    var id: String { step }
    var step: String
    var status: Status
}

struct BoardTask: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var projectID: String
    var hostID: String
    var title: String
    var sourceKind: TaskSourceKind
    var sourceText: String
    var stage: TaskStage
    var autoRun: Bool
    var executionApproved: Bool
    var createdAt: Date
    var updatedAt: Date
    var planText: String
    var hasFinalPlan: Bool
    var structuredPlan: [CodexPlanStep]
    var resultText: String
    var liveMessage: String
    var threadID: String?
    var sessionID: String?
    var planningTurnID: String?
    var executionTurnID: String?
    var model: String?
    var lastError: String?
    var logs: [TaskLogEntry]

    init(
        id: UUID = UUID(),
        projectID: String,
        hostID: String = CodexHost.localID,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        stage: TaskStage = .inbox,
        autoRun: Bool,
        executionApproved: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        planText: String = "",
        hasFinalPlan: Bool = false,
        structuredPlan: [CodexPlanStep] = [],
        resultText: String = "",
        liveMessage: String = "",
        threadID: String? = nil,
        sessionID: String? = nil,
        planningTurnID: String? = nil,
        executionTurnID: String? = nil,
        model: String? = nil,
        lastError: String? = nil,
        logs: [TaskLogEntry] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.hostID = hostID
        self.title = title
        self.sourceKind = sourceKind
        self.sourceText = sourceText
        self.stage = stage
        self.autoRun = autoRun
        self.executionApproved = executionApproved
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planText = planText
        self.hasFinalPlan = hasFinalPlan
        self.structuredPlan = structuredPlan
        self.resultText = resultText
        self.liveMessage = liveMessage
        self.threadID = threadID
        self.sessionID = sessionID
        self.planningTurnID = planningTurnID
        self.executionTurnID = executionTurnID
        self.model = model
        self.lastError = lastError
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case hostID
        case title
        case sourceKind
        case sourceText
        case stage
        case autoRun
        case executionApproved
        case createdAt
        case updatedAt
        case planText
        case hasFinalPlan
        case structuredPlan
        case resultText
        case liveMessage
        case threadID
        case sessionID
        case planningTurnID
        case executionTurnID
        case model
        case lastError
        case logs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectID: try container.decode(String.self, forKey: .projectID),
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID)
                ?? CodexHost.localID,
            title: try container.decode(String.self, forKey: .title),
            sourceKind: try container.decode(TaskSourceKind.self, forKey: .sourceKind),
            sourceText: try container.decode(String.self, forKey: .sourceText),
            stage: try container.decode(TaskStage.self, forKey: .stage),
            autoRun: try container.decode(Bool.self, forKey: .autoRun),
            executionApproved: try container.decode(Bool.self, forKey: .executionApproved),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            planText: try container.decode(String.self, forKey: .planText),
            hasFinalPlan: try container.decode(Bool.self, forKey: .hasFinalPlan),
            structuredPlan: try container.decode([CodexPlanStep].self, forKey: .structuredPlan),
            resultText: try container.decode(String.self, forKey: .resultText),
            liveMessage: try container.decode(String.self, forKey: .liveMessage),
            threadID: try container.decodeIfPresent(String.self, forKey: .threadID),
            sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
            planningTurnID: try container.decodeIfPresent(String.self, forKey: .planningTurnID),
            executionTurnID: try container.decodeIfPresent(String.self, forKey: .executionTurnID),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            logs: try container.decode([TaskLogEntry].self, forKey: .logs)
        )
    }
}

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "超高"
        }
    }
}

struct BoardPreferences: Codable, Equatable, Sendable {
    var defaultAutoRun = false
    var modelOverride = ""
    var planningEffort: ReasoningEffort = .medium
    var executionEffort: ReasoningEffort = .high
    var maxConcurrentExecutions = 2
    var allowNetworkAccess = true
    var showMissingProjects = false
}

struct BoardSnapshot: Codable, Sendable {
    static let currentVersion = 2

    var version: Int
    var tasks: [BoardTask]
    var hosts: [CodexHost]
    var manualProjects: [ManualProjectReference]
    var preferences: BoardPreferences

    var manualProjectPaths: [String] {
        get {
            manualProjects
                .filter { $0.hostID == CodexHost.localID }
                .map(\.path)
        }
        set {
            manualProjects.removeAll { $0.hostID == CodexHost.localID }
            manualProjects.append(contentsOf: newValue.map {
                ManualProjectReference(hostID: CodexHost.localID, path: $0)
            })
        }
    }

    init(
        version: Int = currentVersion,
        tasks: [BoardTask],
        hosts: [CodexHost],
        manualProjects: [ManualProjectReference],
        preferences: BoardPreferences
    ) {
        self.version = max(Self.currentVersion, version)
        self.tasks = tasks
        self.hosts = Self.normalizedHosts(hosts)
        self.manualProjects = manualProjects
        self.preferences = preferences
    }

    init(
        version: Int,
        tasks: [BoardTask],
        manualProjectPaths: [String],
        preferences: BoardPreferences
    ) {
        self.init(
            version: version,
            tasks: tasks,
            hosts: [.local],
            manualProjects: manualProjectPaths.map {
                ManualProjectReference(hostID: CodexHost.localID, path: $0)
            },
            preferences: preferences
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tasks
        case hosts
        case manualProjects
        case manualProjectPaths
        case preferences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = max(
            Self.currentVersion,
            try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        )
        tasks = try container.decode([BoardTask].self, forKey: .tasks)
        hosts = Self.normalizedHosts(
            try container.decodeIfPresent([CodexHost].self, forKey: .hosts) ?? []
        )
        if let references = try container.decodeIfPresent(
            [ManualProjectReference].self,
            forKey: .manualProjects
        ) {
            manualProjects = references
        } else {
            manualProjects = try container.decodeIfPresent(
                [String].self,
                forKey: .manualProjectPaths
            )?.map {
                ManualProjectReference(hostID: CodexHost.localID, path: $0)
            } ?? []
        }
        preferences = try container.decode(BoardPreferences.self, forKey: .preferences)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(max(Self.currentVersion, version), forKey: .version)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(Self.normalizedHosts(hosts), forKey: .hosts)
        try container.encode(manualProjects, forKey: .manualProjects)
        try container.encode(preferences, forKey: .preferences)
    }

    private static func normalizedHosts(_ hosts: [CodexHost]) -> [CodexHost] {
        var seenIDs: Set<String> = []
        var normalized: [CodexHost] = []
        for host in hosts where seenIDs.insert(host.id).inserted {
            if host.id == CodexHost.localID, host.kind != .local {
                normalized.append(.local)
            } else {
                normalized.append(host)
            }
        }
        if !seenIDs.contains(CodexHost.localID) {
            normalized.insert(.local, at: 0)
        }
        return normalized
    }

    static let empty = BoardSnapshot(
        version: currentVersion,
        tasks: [],
        hosts: [.local],
        manualProjects: [],
        preferences: BoardPreferences()
    )
}
