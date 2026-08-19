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

    private enum CodingKeys: String, CodingKey {
        case hostID
        case path
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            ?? CodexHost.localID
        path = try container.decode(String.self, forKey: .path)
    }
}

enum TaskSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case issue
    case developmentPlan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .issue: "Issue"
        case .developmentPlan: L10n.text("task.source.development_plan", fallback: "Development Plan")
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
        case .inbox: L10n.text("task.stage.inbox", fallback: "Inbox")
        case .planning: L10n.text("task.stage.planning", fallback: "Planning")
        case .awaitingApproval: L10n.text("task.stage.awaiting_approval", fallback: "Approval")
        case .executing: L10n.text("task.stage.executing", fallback: "Executing")
        case .review: L10n.text("task.stage.review", fallback: "Review")
        case .completed: L10n.text("task.stage.completed", fallback: "Completed")
        case .needsAttention: L10n.text("task.stage.needs_attention", fallback: "Needs Attention")
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
    var manualPriority: Int?

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
        isManual: Bool = false,
        manualPriority: Int? = nil
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
        self.manualPriority = manualPriority
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
        isManual: Bool = false,
        manualPriority: Int? = nil
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
            isManual: isManual,
            manualPriority: manualPriority
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
        case manualPriority
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            ?? CodexHost.localID
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        observedWorkingDirectories = try container.decodeIfPresent(
            [String].self,
            forKey: .observedWorkingDirectories
        ) ?? []
        manualPaths = try container.decodeIfPresent([String].self, forKey: .manualPaths) ?? []
        latestActivityAt = try container.decodeIfPresent(Date.self, forKey: .latestActivityAt)
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount) ?? 0
        activeThreadCount = try container.decodeIfPresent(Int.self, forKey: .activeThreadCount) ?? 0
        isGitRepository = try container.decodeIfPresent(Bool.self, forKey: .isGitRepository) ?? false
        existsOnDisk = try container.decodeIfPresent(Bool.self, forKey: .existsOnDisk) ?? true
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        manualPriority = try container.decodeIfPresent(Int.self, forKey: .manualPriority)
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
        try container.encodeIfPresent(manualPriority, forKey: .manualPriority)
    }

    private static func identifier(hostID: String, path: String) -> String {
        guard hostID != CodexHost.localID else { return path }
        return "host:\(hostID.utf8.count):\(hostID):\(path)"
    }
}

struct TaskAttachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case file

        var title: String {
            switch self {
            case .image: L10n.text("attachment.kind.image", fallback: "Image")
            case .file: L10n.text("attachment.kind.file", fallback: "File")
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

struct TaskSkillSelection: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }

    let name: String
    let description: String
    let path: String
    let scope: String
}

struct TaskAppSelection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let invocationName: String
    let description: String
    let requiresApproval: Bool

    init(
        id: String,
        name: String,
        invocationName: String,
        description: String,
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.name = name
        self.invocationName = invocationName
        self.description = description
        self.requiresApproval = requiresApproval
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, invocationName, description, requiresApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        invocationName = try container.decode(String.self, forKey: .invocationName)
        description = try container.decode(String.self, forKey: .description)
        requiresApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
    }
}

struct BoardTask: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var projectID: String
    var hostID: String
    var title: String
    var sourceKind: TaskSourceKind
    var sourceText: String
    var attachments: [TaskAttachment]
    var selectedSkills: [TaskSkillSelection]
    var selectedApps: [TaskAppSelection]
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
    var dependencyIDs: [UUID]
    var failureState: TaskFailureState?
    var attention: TaskAttention?

    init(
        id: UUID = UUID(),
        projectID: String,
        hostID: String = CodexHost.localID,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        attachments: [TaskAttachment] = [],
        selectedSkills: [TaskSkillSelection] = [],
        selectedApps: [TaskAppSelection] = [],
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
        workspace: TaskWorkspaceConfiguration = .project,
        dependencyIDs: [UUID] = [],
        failureState: TaskFailureState? = nil,
        attention: TaskAttention? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.hostID = hostID
        self.title = title
        self.sourceKind = sourceKind
        self.sourceText = sourceText
        self.attachments = attachments
        self.selectedSkills = selectedSkills
        self.selectedApps = selectedApps
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
        self.dependencyIDs = dependencyIDs
        self.failureState = failureState
        self.attention = attention
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, hostID, title, sourceKind, sourceText, attachments, selectedSkills, selectedApps
        case stage, autoRun
        case executionApproved, createdAt, updatedAt, planText, hasFinalPlan, structuredPlan
        case resultText, liveMessage, threadID, sessionID, planningTurnID, executionTurnID
        case requestedModel, reasoningEffort, fastMode, actualModel, lastError, logs
        case runs, reviewFeedback, workspace, dependencyIDs, failureState, attention
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            ?? CodexHost.localID
        title = try container.decode(String.self, forKey: .title)
        sourceKind = try container.decode(TaskSourceKind.self, forKey: .sourceKind)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments) ?? []
        selectedSkills = try container.decodeIfPresent([TaskSkillSelection].self, forKey: .selectedSkills) ?? []
        selectedApps = try container.decodeIfPresent([TaskAppSelection].self, forKey: .selectedApps) ?? []
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
        dependencyIDs = try container.decodeIfPresent([UUID].self, forKey: .dependencyIDs) ?? []
        failureState = try container.decodeIfPresent(TaskFailureState.self, forKey: .failureState)
        attention = try container.decodeIfPresent(TaskAttention.self, forKey: .attention)
    }
}

/// The small, render-facing subset of a task used by the board and menu bar.
/// Streaming plan/result text and logs are intentionally excluded so a token
/// delta does not invalidate every visible card.
struct BoardTaskCard: Hashable, Identifiable, Sendable {
    let id: UUID
    let projectID: String
    let hostID: String
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
    let artifactCount: Int
    let hasCodeDelivery: Bool
    let latestAgentActivityKind: String?
    let latestAgentPath: String?
    let rootThreadTotalTokens: Int64?
    let workspaceKind: TaskWorkspaceKind
    let dependencyCount: Int
    let blockingDependencyCount: Int
    let failureKind: TaskFailureKind?
    let circuitOpen: Bool

    init(task: BoardTask, blockingDependencyCount: Int = 0) {
        id = task.id
        projectID = task.projectID
        hostID = task.hostID
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
        artifactCount = task.latestDeliveryEvidence?.artifacts.count ?? 0
        hasCodeDelivery = task.latestCodeDelivery != nil
        // Never project telemetry from an older attempt onto a newer run that
        // has not emitted any observations yet.
        let observedRun = task.runs.last
        let latestActivity = observedRun?.telemetry?.agentActivities.max { lhs, rhs in
            let lhsDate = lhs.completedAt ?? lhs.startedAt ?? .distantPast
            let rhsDate = rhs.completedAt ?? rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id < rhs.id
        }
        let activityKind = latestActivity?.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        latestAgentActivityKind = activityKind.flatMap { $0.isEmpty ? nil : $0 }
        let agentPath = latestActivity?.agentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        latestAgentPath = agentPath.flatMap { $0.isEmpty ? nil : $0 }
        rootThreadTotalTokens = observedRun.flatMap { run in
            guard let rootThreadID = run.threadID else { return nil }
            return run.telemetry?.tokenUsageByThread
                .filter { $0.threadID == rootThreadID }
                .max(by: { $0.receivedAt < $1.receivedAt })?
                .total.totalTokens
        }
        workspaceKind = task.workspace.kind
        dependencyCount = task.dependencyIDs.count
        self.blockingDependencyCount = blockingDependencyCount
        failureKind = task.failureState?.kind
        circuitOpen = task.failureState?.circuitOpen == true
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
        case Self.low.rawValue: L10n.text("effort.low", fallback: "Low")
        case Self.medium.rawValue: L10n.text("effort.medium", fallback: "Medium")
        case Self.high.rawValue: L10n.text("effort.high", fallback: "High")
        case Self.xhigh.rawValue: L10n.text("effort.xhigh", fallback: "Extra High")
        case Self.max.rawValue: L10n.text("effort.max", fallback: "Max")
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
    var maxAutomaticRetries = 2
    var allowNetworkAccess = true
    var showMissingProjects = false

    private enum CodingKeys: String, CodingKey {
        case defaultAutoRun, modelOverride, planningEffort, executionEffort
        case maxConcurrentExecutions, maxAutomaticRetries, allowNetworkAccess, showMissingProjects
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultAutoRun = try container.decodeIfPresent(Bool.self, forKey: .defaultAutoRun) ?? false
        modelOverride = try container.decodeIfPresent(String.self, forKey: .modelOverride) ?? ""
        planningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .planningEffort) ?? .medium
        executionEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .executionEffort) ?? .high
        maxConcurrentExecutions = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentExecutions) ?? 2
        maxAutomaticRetries = try container.decodeIfPresent(Int.self, forKey: .maxAutomaticRetries) ?? 2
        allowNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowNetworkAccess) ?? true
        showMissingProjects = try container.decodeIfPresent(Bool.self, forKey: .showMissingProjects) ?? false
    }
}

struct BoardSnapshot: Codable, Sendable {
    static let currentVersion = 13

    var version: Int
    var tasks: [BoardTask]
    var hosts: [CodexHost]
    var manualProjects: [ManualProjectReference]
    var preferences: BoardPreferences
    var hiddenProjectPaths: [String]

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
        preferences: BoardPreferences,
        hiddenProjectPaths: [String] = []
    ) {
        // An in-memory snapshot always represents the schema understood by this
        // build. Older versions are normalized while decoding; newer versions
        // must be rejected there instead of being silently rewritten.
        self.version = Self.currentVersion
        self.tasks = tasks
        self.hosts = Self.normalizedHosts(
            hosts,
            fallbackLocalConcurrency: preferences.maxConcurrentExecutions
        )
        self.manualProjects = manualProjects
        self.preferences = preferences
        self.hiddenProjectPaths = hiddenProjectPaths
    }

    init(
        version: Int,
        tasks: [BoardTask],
        manualProjectPaths: [String],
        preferences: BoardPreferences,
        hiddenProjectPaths: [String] = []
    ) {
        self.init(
            version: version,
            tasks: tasks,
            hosts: [],
            manualProjects: manualProjectPaths.map {
                ManualProjectReference(hostID: CodexHost.localID, path: $0)
            },
            preferences: preferences,
            hiddenProjectPaths: hiddenProjectPaths
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tasks
        case hosts
        case manualProjects
        case manualProjectPaths
        case preferences
        case hiddenProjectPaths
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported CodexBoard snapshot version \(storedVersion); this build supports versions 1 through \(Self.currentVersion)."
            )
        }
        version = Self.currentVersion
        tasks = try container.decode([BoardTask].self, forKey: .tasks)
        preferences = try container.decode(BoardPreferences.self, forKey: .preferences)
        hosts = Self.normalizedHosts(
            try container.decodeIfPresent([CodexHost].self, forKey: .hosts) ?? [],
            fallbackLocalConcurrency: preferences.maxConcurrentExecutions
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
        hiddenProjectPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .hiddenProjectPaths
        ) ?? []

        // Snapshots written before task-scoped runtime configuration must keep
        // the effective effort that the mainline migration already selected.
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(
            Self.normalizedHosts(
                hosts,
                fallbackLocalConcurrency: preferences.maxConcurrentExecutions
            ),
            forKey: .hosts
        )
        try container.encode(manualProjects, forKey: .manualProjects)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(hiddenProjectPaths, forKey: .hiddenProjectPaths)
    }

    private static func normalizedHosts(
        _ hosts: [CodexHost],
        fallbackLocalConcurrency: Int
    ) -> [CodexHost] {
        let fallbackLocalHost = CodexHost(
            id: CodexHost.localID,
            name: CodexHost.local.name,
            kind: .local,
            isEnabled: true,
            maxConcurrentExecutions: max(1, fallbackLocalConcurrency)
        )
        var seenIDs: Set<String> = []
        var normalized: [CodexHost] = []
        for host in hosts where seenIDs.insert(host.id).inserted {
            if host.id == CodexHost.localID, host.kind != .local {
                normalized.append(fallbackLocalHost)
            } else {
                normalized.append(host)
            }
        }
        if !seenIDs.contains(CodexHost.localID) {
            normalized.insert(fallbackLocalHost, at: 0)
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
