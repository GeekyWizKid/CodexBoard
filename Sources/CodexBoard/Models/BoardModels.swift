import Foundation

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
    let id: String
    var name: String
    var path: String
    var observedWorkingDirectories: [String]
    var latestActivityAt: Date?
    var threadCount: Int
    var activeThreadCount: Int
    var isGitRepository: Bool
    var existsOnDisk: Bool
    var isManual: Bool

    init(
        id: String,
        name: String,
        path: String,
        observedWorkingDirectories: [String] = [],
        latestActivityAt: Date? = nil,
        threadCount: Int = 0,
        activeThreadCount: Int = 0,
        isGitRepository: Bool = false,
        existsOnDisk: Bool = true,
        isManual: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.observedWorkingDirectories = observedWorkingDirectories
        self.latestActivityAt = latestActivityAt
        self.threadCount = threadCount
        self.activeThreadCount = activeThreadCount
        self.isGitRepository = isGitRepository
        self.existsOnDisk = existsOnDisk
        self.isManual = isManual
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
    var version: Int
    var tasks: [BoardTask]
    var manualProjectPaths: [String]
    var preferences: BoardPreferences

    static let empty = BoardSnapshot(
        version: 1,
        tasks: [],
        manualProjectPaths: [],
        preferences: BoardPreferences()
    )
}
