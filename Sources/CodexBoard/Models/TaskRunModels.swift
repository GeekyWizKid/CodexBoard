import Foundation

enum TaskWorkspaceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case project
    case worktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: L10n.text("workspace.project", fallback: "Current Project")
        case .worktree: L10n.text("workspace.worktree", fallback: "Isolated Worktree")
        }
    }
}

struct TaskWorkspaceConfiguration: Codable, Hashable, Sendable {
    var kind: TaskWorkspaceKind
    var path: String?
    var branch: String?
    var baseBranch: String?

    static let project = TaskWorkspaceConfiguration(kind: .project)

    init(
        kind: TaskWorkspaceKind,
        path: String? = nil,
        branch: String? = nil,
        baseBranch: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.branch = branch
        self.baseBranch = baseBranch
    }
}

struct TaskDependencyHandoff: Hashable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let changedFiles: [String]
    let testSummary: String
    let commitSHA: String?
    let pullRequestURL: String?
}

enum TaskFailureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case startup
    case authentication
    case rateLimit
    case workspace
    case connection
    case execution
    case interrupted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startup: L10n.text("failure.startup", fallback: "Startup Failed")
        case .authentication: L10n.text("failure.authentication", fallback: "Authentication Failed")
        case .rateLimit: L10n.text("failure.rate_limit", fallback: "Rate Limited")
        case .workspace: L10n.text("failure.workspace", fallback: "Workspace Failed")
        case .connection: L10n.text("failure.connection", fallback: "Connection Lost")
        case .execution: L10n.text("failure.execution", fallback: "Execution Failed")
        case .interrupted: L10n.text("failure.interrupted", fallback: "Stopped Manually")
        }
    }
}

struct TaskFailureState: Codable, Hashable, Sendable {
    var kind: TaskFailureKind
    var consecutiveCount: Int
    var automaticRetryCount: Int
    var circuitOpen: Bool
    var occurredAt: Date
    var nextRetryAt: Date?
    var message: String

    init(
        kind: TaskFailureKind,
        consecutiveCount: Int = 1,
        automaticRetryCount: Int = 0,
        circuitOpen: Bool = false,
        occurredAt: Date = Date(),
        nextRetryAt: Date? = nil,
        message: String
    ) {
        self.kind = kind
        self.consecutiveCount = consecutiveCount
        self.automaticRetryCount = automaticRetryCount
        self.circuitOpen = circuitOpen
        self.occurredAt = occurredAt
        self.nextRetryAt = nextRetryAt
        self.message = message
    }
}

enum TaskRunPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case planning
    case execution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .planning: L10n.text("run.phase.planning", fallback: "Planning")
        case .execution: L10n.text("run.phase.execution", fallback: "Execution")
        }
    }

    var symbol: String {
        switch self {
        case .planning: "sparkles"
        case .execution: "hammer"
        }
    }
}

enum TaskRunOutcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case running
    case completed
    case awaitingReview
    case accepted
    case changesRequested
    case failed
    case interrupted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: L10n.text("run.outcome.running", fallback: "Running")
        case .completed: L10n.text("run.outcome.completed", fallback: "Completed")
        case .awaitingReview: L10n.text("run.outcome.awaiting_review", fallback: "Awaiting Review")
        case .accepted: L10n.text("run.outcome.accepted", fallback: "Accepted")
        case .changesRequested: L10n.text("run.outcome.changes_requested", fallback: "Changes Requested")
        case .failed: L10n.text("run.outcome.failed", fallback: "Failed")
        case .interrupted: L10n.text("run.outcome.interrupted", fallback: "Stopped")
        }
    }

    var isActive: Bool { self == .running }
}

struct TaskDeliveryArtifact: Codable, Hashable, Sendable {
    var title: String
    var path: String
    var kind: String

    init(title: String = "", path: String, kind: String = "file") {
        self.title = title
        self.path = path
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case title, path, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "file"
    }
}

struct TaskCodeDelivery: Codable, Hashable, Sendable {
    static let maximumStoredBytes = 1_500_000

    var unifiedDiff: String
    var isTruncated: Bool

    init(unifiedDiff: String, isTruncated: Bool = false) {
        self.unifiedDiff = unifiedDiff
        self.isTruncated = isTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case unifiedDiff, isTruncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unifiedDiff = try container.decodeIfPresent(String.self, forKey: .unifiedDiff) ?? ""
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }

    static func capturing(_ diff: String) -> TaskCodeDelivery? {
        guard diff.contains(where: { !$0.isWhitespace }) else { return nil }
        guard diff.utf8.count > maximumStoredBytes else {
            return TaskCodeDelivery(unifiedDiff: diff)
        }

        var stored = String(decoding: Data(diff.utf8.prefix(maximumStoredBytes)), as: UTF8.self)
        if let finalNewline = stored.lastIndex(of: "\n"),
           stored.distance(from: finalNewline, to: stored.endIndex) < 8_192 {
            stored = String(stored[...finalNewline])
        }
        return TaskCodeDelivery(unifiedDiff: stored, isTruncated: true)
    }
}

struct TaskDeliveryEvidence: Codable, Hashable, Sendable {
    var summary: String
    var changedFiles: [String]
    var artifacts: [TaskDeliveryArtifact]
    var verificationCommands: [String]
    var testSummary: String
    var commitSHA: String?
    var pullRequestURL: String?
    var residualRisks: [String]

    init(
        summary: String = "",
        changedFiles: [String] = [],
        artifacts: [TaskDeliveryArtifact] = [],
        verificationCommands: [String] = [],
        testSummary: String = "",
        commitSHA: String? = nil,
        pullRequestURL: String? = nil,
        residualRisks: [String] = []
    ) {
        self.summary = summary
        self.changedFiles = changedFiles
        self.artifacts = artifacts
        self.verificationCommands = verificationCommands
        self.testSummary = testSummary
        self.commitSHA = commitSHA
        self.pullRequestURL = pullRequestURL
        self.residualRisks = residualRisks
    }

    var hasStructuredDetails: Bool {
        !changedFiles.isEmpty
            || !artifacts.isEmpty
            || !verificationCommands.isEmpty
            || !testSummary.isEmpty
            || commitSHA != nil
            || pullRequestURL != nil
            || !residualRisks.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case summary, changedFiles, artifacts, verificationCommands, testSummary
        case commitSHA, pullRequestURL, residualRisks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        artifacts = try container.decodeIfPresent([TaskDeliveryArtifact].self, forKey: .artifacts) ?? []
        verificationCommands = try container.decodeIfPresent([String].self, forKey: .verificationCommands) ?? []
        testSummary = try container.decodeIfPresent(String.self, forKey: .testSummary) ?? ""
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
        pullRequestURL = try container.decodeIfPresent(String.self, forKey: .pullRequestURL)
        residualRisks = try container.decodeIfPresent([String].self, forKey: .residualRisks) ?? []
    }
}

enum TaskRunContextMode: String, Codable, Hashable, Sendable {
    case freshThread
    case reusedThread
}

struct TaskRunContinuation: Codable, Hashable, Sendable {
    let mode: TaskRunContextMode
    let sourceRunID: UUID?

    init(mode: TaskRunContextMode, sourceRunID: UUID? = nil) {
        self.mode = mode
        self.sourceRunID = sourceRunID
    }
}

enum TaskRunSandboxMode: String, Codable, Hashable, Sendable {
    case readOnly
    case workspaceWrite
}

enum TaskRunApprovalPolicy: String, Codable, Hashable, Sendable {
    case never
    case onRequest
}

struct TaskRunWorkspaceSnapshot: Codable, Hashable, Sendable {
    let kind: TaskWorkspaceKind
    let path: String
    let branch: String?
    let baseBranch: String?

    init(
        kind: TaskWorkspaceKind,
        path: String,
        branch: String? = nil,
        baseBranch: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.branch = branch
        self.baseBranch = baseBranch
    }
}

struct TaskRunPolicySnapshot: Codable, Hashable, Sendable {
    let hostID: String
    let workspace: TaskRunWorkspaceSnapshot
    let sandboxMode: TaskRunSandboxMode
    let approvalPolicy: TaskRunApprovalPolicy
    let networkAccess: Bool
    let writableRoots: [String]
    let serviceTier: String
}

enum TaskRunRecoveryDisposition: String, Codable, Hashable, Sendable {
    case none
    case automaticRetryScheduled
    case manualInterventionRequired
    case reconcileBeforeRetry
}

struct TaskRunFailure: Codable, Hashable, Sendable {
    let kind: TaskFailureKind
    let message: String
    let occurredAt: Date
    let recoveryDisposition: TaskRunRecoveryDisposition
    let nextRetryAt: Date?
    let consecutiveCount: Int
    let automaticRetryCount: Int

    init(
        kind: TaskFailureKind,
        message: String,
        occurredAt: Date = Date(),
        recoveryDisposition: TaskRunRecoveryDisposition,
        nextRetryAt: Date? = nil,
        consecutiveCount: Int = 1,
        automaticRetryCount: Int = 0
    ) {
        self.kind = kind
        self.message = message
        self.occurredAt = occurredAt
        self.recoveryDisposition = recoveryDisposition
        self.nextRetryAt = nextRetryAt
        self.consecutiveCount = consecutiveCount
        self.automaticRetryCount = automaticRetryCount
    }
}

struct TaskRun: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var phase: TaskRunPhase
    var attempt: Int
    var startedAt: Date
    var endedAt: Date?
    var outcome: TaskRunOutcome
    var threadID: String?
    var sessionID: String?
    var turnID: String?
    var model: String?
    var reasoningEffort: ReasoningEffort
    var fastMode: Bool
    var continuation: TaskRunContinuation?
    var policySnapshot: TaskRunPolicySnapshot?
    var failure: TaskRunFailure?
    var summary: String
    var evidence: TaskDeliveryEvidence?
    var codeDelivery: TaskCodeDelivery?
    var error: String?
    var reviewNote: String?
    var reviewedAt: Date?

    init(
        id: UUID = UUID(),
        phase: TaskRunPhase,
        attempt: Int,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcome: TaskRunOutcome = .running,
        threadID: String? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        model: String? = nil,
        reasoningEffort: ReasoningEffort,
        fastMode: Bool,
        continuation: TaskRunContinuation? = nil,
        policySnapshot: TaskRunPolicySnapshot? = nil,
        failure: TaskRunFailure? = nil,
        summary: String = "",
        evidence: TaskDeliveryEvidence? = nil,
        codeDelivery: TaskCodeDelivery? = nil,
        error: String? = nil,
        reviewNote: String? = nil,
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.phase = phase
        self.attempt = attempt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.threadID = threadID
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.continuation = continuation
        self.policySnapshot = policySnapshot
        self.failure = failure
        self.summary = summary
        self.evidence = evidence
        self.codeDelivery = codeDelivery
        self.error = error
        self.reviewNote = reviewNote
        self.reviewedAt = reviewedAt
    }
}

extension BoardTask {
    var latestExecutionRun: TaskRun? {
        runs.last(where: { $0.phase == .execution })
    }

    var latestDeliveryEvidence: TaskDeliveryEvidence? {
        latestExecutionRun?.evidence
    }

    var latestCodeDelivery: TaskCodeDelivery? {
        latestExecutionRun?.codeDelivery
    }

    var hasDeliverables: Bool {
        latestDeliveryEvidence?.hasStructuredDetails == true || latestCodeDelivery != nil
    }

    var executionAttemptCount: Int {
        runs.count(where: { $0.phase == .execution })
    }
}
