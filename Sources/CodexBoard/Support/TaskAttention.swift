import Foundation

struct TaskFocusRequest: Equatable, Sendable {
    let taskID: UUID
    let stage: TaskStage
    let nonce: UUID
}

struct TaskAttentionNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case interaction
        case planApproval
    }

    let id: UUID
    let taskID: UUID
    let kind: Kind
    let createdAt: Date
}
