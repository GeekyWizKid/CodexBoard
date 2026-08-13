import Foundation

enum TaskWorkspaceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case project
    case worktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "当前项目"
        case .worktree: "独立 Worktree"
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

enum TaskRunPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case planning
    case execution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .planning: "规划"
        case .execution: "执行"
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
        case .running: "运行中"
        case .completed: "已完成"
        case .awaitingReview: "等待验收"
        case .accepted: "验收通过"
        case .changesRequested: "要求修改"
        case .failed: "失败"
        case .interrupted: "已停止"
        }
    }

    var isActive: Bool { self == .running }
}

struct TaskDeliveryEvidence: Codable, Hashable, Sendable {
    var summary: String
    var changedFiles: [String]
    var verificationCommands: [String]
    var testSummary: String
    var commitSHA: String?
    var pullRequestURL: String?
    var residualRisks: [String]

    init(
        summary: String = "",
        changedFiles: [String] = [],
        verificationCommands: [String] = [],
        testSummary: String = "",
        commitSHA: String? = nil,
        pullRequestURL: String? = nil,
        residualRisks: [String] = []
    ) {
        self.summary = summary
        self.changedFiles = changedFiles
        self.verificationCommands = verificationCommands
        self.testSummary = testSummary
        self.commitSHA = commitSHA
        self.pullRequestURL = pullRequestURL
        self.residualRisks = residualRisks
    }

    var hasStructuredDetails: Bool {
        !changedFiles.isEmpty
            || !verificationCommands.isEmpty
            || !testSummary.isEmpty
            || commitSHA != nil
            || pullRequestURL != nil
            || !residualRisks.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case summary, changedFiles, verificationCommands, testSummary
        case commitSHA, pullRequestURL, residualRisks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        verificationCommands = try container.decodeIfPresent([String].self, forKey: .verificationCommands) ?? []
        testSummary = try container.decodeIfPresent(String.self, forKey: .testSummary) ?? ""
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
        pullRequestURL = try container.decodeIfPresent(String.self, forKey: .pullRequestURL)
        residualRisks = try container.decodeIfPresent([String].self, forKey: .residualRisks) ?? []
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
    var summary: String
    var evidence: TaskDeliveryEvidence?
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
        summary: String = "",
        evidence: TaskDeliveryEvidence? = nil,
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
        self.summary = summary
        self.evidence = evidence
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

    var executionAttemptCount: Int {
        runs.count(where: { $0.phase == .execution })
    }
}
