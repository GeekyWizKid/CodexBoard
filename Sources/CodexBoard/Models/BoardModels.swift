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
    case review
    case completed
    case needsAttention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "待办"
        case .planning: "规划中"
        case .awaitingApproval: "待确认"
        case .executing: "执行中"
        case .review: "待验收"
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
        case .review: "checkmark.bubble"
        case .completed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var allowsManualDrop: Bool {
        switch self {
        case .planning, .executing, .review: false
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
    var manualPriority: Int?

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
        isManual: Bool = false,
        manualPriority: Int? = nil
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
        self.manualPriority = manualPriority
    }
}

struct TaskAttachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case file

        var title: String {
            switch self {
            case .image: "图片"
            case .file: "文件"
            }
        }

        var symbol: String {
            switch self {
            case .image: "photo"
            case .file: "doc"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var displayName: String
    var path: String
    var byteCount: Int64?
    var isManaged: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        path: String,
        byteCount: Int64? = nil,
        isManaged: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.byteCount = byteCount
        self.isManaged = isManaged
    }
}

struct TaskAttachmentDraft: Identifiable, Sendable {
    enum Source: Sendable {
        case file(URL)
        case pastedImage(Data)
    }

    let id: UUID
    var displayName: String
    var byteCount: Int64?
    var source: Source

    init(
        id: UUID = UUID(),
        displayName: String,
        byteCount: Int64? = nil,
        source: Source
    ) {
        self.id = id
        self.displayName = displayName
        self.byteCount = byteCount
        self.source = source
    }

    static func file(_ url: URL) -> TaskAttachmentDraft {
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey])
        return TaskAttachmentDraft(
            displayName: standardizedURL.lastPathComponent,
            byteCount: values?.fileSize.map(Int64.init),
            source: .file(standardizedURL)
        )
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
    var attachments: [TaskAttachment]
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
    var requestedModel: String
    var reasoningEffort: ReasoningEffort
    var fastMode: Bool
    var actualModel: String?
    var lastError: String?
    var logs: [TaskLogEntry]
    // This is intentionally not encoded. It only lets BoardSnapshot distinguish
    // tasks loaded from the pre-task-options format while decoding.
    var runtimeConfigurationWasPersisted: Bool
    var runs: [TaskRun]
    var reviewFeedback: String?
    var workspace: TaskWorkspaceConfiguration

    init(
        id: UUID = UUID(),
        projectID: String,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        attachments: [TaskAttachment] = [],
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
        requestedModel: String = "",
        reasoningEffort: ReasoningEffort = .medium,
        fastMode: Bool = false,
        actualModel: String? = nil,
        lastError: String? = nil,
        logs: [TaskLogEntry] = [],
        runs: [TaskRun] = [],
        reviewFeedback: String? = nil,
        workspace: TaskWorkspaceConfiguration = .project
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.sourceKind = sourceKind
        self.sourceText = sourceText
        self.attachments = attachments
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
        self.requestedModel = requestedModel
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.actualModel = actualModel
        self.lastError = lastError
        self.logs = logs
        self.runtimeConfigurationWasPersisted = true
        self.runs = runs
        self.reviewFeedback = reviewFeedback
        self.workspace = workspace
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, sourceKind, sourceText, attachments, stage, autoRun
        case executionApproved, createdAt, updatedAt, planText, hasFinalPlan, structuredPlan
        case resultText, liveMessage, threadID, sessionID, planningTurnID, executionTurnID
        case requestedModel, reasoningEffort, fastMode, actualModel, lastError, logs
        case runs, reviewFeedback, workspace
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        title = try container.decode(String.self, forKey: .title)
        sourceKind = try container.decode(TaskSourceKind.self, forKey: .sourceKind)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments) ?? []
        stage = try container.decode(TaskStage.self, forKey: .stage)
        autoRun = try container.decode(Bool.self, forKey: .autoRun)
        executionApproved = try container.decode(Bool.self, forKey: .executionApproved)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        planText = try container.decode(String.self, forKey: .planText)
        hasFinalPlan = try container.decodeIfPresent(Bool.self, forKey: .hasFinalPlan) ?? false
        structuredPlan = try container.decode([CodexPlanStep].self, forKey: .structuredPlan)
        resultText = try container.decode(String.self, forKey: .resultText)
        liveMessage = try container.decode(String.self, forKey: .liveMessage)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        planningTurnID = try container.decodeIfPresent(String.self, forKey: .planningTurnID)
        executionTurnID = try container.decodeIfPresent(String.self, forKey: .executionTurnID)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyModel = try legacyContainer.decodeIfPresent(String.self, forKey: .model)
        requestedModel = try container.decodeIfPresent(String.self, forKey: .requestedModel)
            ?? legacyModel
            ?? ""
        runtimeConfigurationWasPersisted = container.contains(.reasoningEffort)
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .medium
        fastMode = try container.decodeIfPresent(Bool.self, forKey: .fastMode) ?? false
        actualModel = try container.decodeIfPresent(String.self, forKey: .actualModel) ?? legacyModel
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        logs = try container.decode([TaskLogEntry].self, forKey: .logs)
        runs = try container.decodeIfPresent([TaskRun].self, forKey: .runs) ?? []
        reviewFeedback = try container.decodeIfPresent(String.self, forKey: .reviewFeedback)
        workspace = try container.decodeIfPresent(TaskWorkspaceConfiguration.self, forKey: .workspace) ?? .project
    }
}

/// The small, render-facing subset of a task used by the board and menu bar.
/// Streaming plan/result text and logs are intentionally excluded so a token
/// delta does not invalidate every visible card.
struct BoardTaskCard: Hashable, Identifiable, Sendable {
    let id: UUID
    let projectID: String
    let title: String
    let sourceKind: TaskSourceKind
    let stage: TaskStage
    let autoRun: Bool
    let executionApproved: Bool
    let attachmentCount: Int
    let liveMessage: String
    let updatedAt: Date
    let model: String?
    let canContinueExecution: Bool
    let executionAttemptCount: Int
    let hasDeliveryEvidence: Bool

    init(task: BoardTask) {
        id = task.id
        projectID = task.projectID
        title = task.title
        sourceKind = task.sourceKind
        stage = task.stage
        autoRun = task.autoRun
        executionApproved = task.executionApproved
        attachmentCount = task.attachments.count
        liveMessage = task.liveMessage
        updatedAt = task.updatedAt
        model = task.actualModel ?? (task.requestedModel.isEmpty ? nil : task.requestedModel)
        canContinueExecution = task.stage == .needsAttention
            && task.hasFinalPlan
            && !task.planText.isEmpty
        executionAttemptCount = task.executionAttemptCount
        hasDeliveryEvidence = task.latestDeliveryEvidence?.hasStructuredDetails == true
    }
}

struct ReasoningEffort: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let low = ReasoningEffort(rawValue: "low")
    static let medium = ReasoningEffort(rawValue: "medium")
    static let high = ReasoningEffort(rawValue: "high")
    static let xhigh = ReasoningEffort(rawValue: "xhigh")
    static let max = ReasoningEffort(rawValue: "max")
    static let ultra = ReasoningEffort(rawValue: "ultra")

    static let standardCases: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max, .ultra]

    var id: String { rawValue }

    var title: String {
        switch rawValue {
        case Self.low.rawValue: "低"
        case Self.medium.rawValue: "中"
        case Self.high.rawValue: "高"
        case Self.xhigh.rawValue: "超高"
        case Self.max.rawValue: "最大"
        case Self.ultra.rawValue: "Ultra"
        default: rawValue
        }
    }
}

struct BoardPreferences: Codable, Equatable, Sendable {
    var defaultAutoRun = false
    var modelOverride = ""
    var planningEffort: ReasoningEffort = .medium
    // Kept in snapshots for backward compatibility. New tasks freeze one
    // selected effort for both planning and execution.
    var executionEffort: ReasoningEffort = .high
    var maxConcurrentExecutions = 2
    var allowNetworkAccess = true
    var showMissingProjects = false
}

struct BoardSnapshot: Codable, Sendable {
    static let currentVersion = 4

    var version: Int
    var tasks: [BoardTask]
    var manualProjectPaths: [String]
    var preferences: BoardPreferences

    init(
        version: Int,
        tasks: [BoardTask],
        manualProjectPaths: [String],
        preferences: BoardPreferences
    ) {
        self.version = version
        self.tasks = tasks
        self.manualProjectPaths = manualProjectPaths
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case version, tasks, manualProjectPaths, preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tasks = try container.decode([BoardTask].self, forKey: .tasks)
        manualProjectPaths = try container.decode([String].self, forKey: .manualProjectPaths)
        preferences = try container.decode(BoardPreferences.self, forKey: .preferences)

        for index in tasks.indices where !tasks[index].runtimeConfigurationWasPersisted {
            let task = tasks[index]
            let shouldPreserveExecutionEffort: Bool
            switch task.stage {
            case .awaitingApproval, .executing, .review, .completed:
                shouldPreserveExecutionEffort = true
            case .needsAttention:
                shouldPreserveExecutionEffort = task.hasFinalPlan && !task.planText.isEmpty
            case .inbox, .planning:
                shouldPreserveExecutionEffort = false
            }
            tasks[index].reasoningEffort = shouldPreserveExecutionEffort
                ? preferences.executionEffort
                : preferences.planningEffort
            tasks[index].runtimeConfigurationWasPersisted = true
        }
    }

    static let empty = BoardSnapshot(
        version: currentVersion,
        tasks: [],
        manualProjectPaths: [],
        preferences: BoardPreferences()
    )
}
