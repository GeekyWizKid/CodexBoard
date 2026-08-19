import Foundation

struct TaskFocusRequest: Equatable, Sendable {
    let taskID: UUID
    let stage: TaskStage
    let nonce: UUID
}

enum TaskAttentionKind: String, Codable, Hashable, Sendable {
    case planApproval
    case failure
}

struct TaskAttention: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var kind: TaskAttentionKind
    var runID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: TaskAttentionKind,
        runID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.runID = runID
        self.createdAt = createdAt
    }
}

struct TaskAttentionNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case interaction
        case planApproval
        case failure
    }

    let id: UUID
    let taskID: UUID
    let kind: Kind
    let createdAt: Date
}
