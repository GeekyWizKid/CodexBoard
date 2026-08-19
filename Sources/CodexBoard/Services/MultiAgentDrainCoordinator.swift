import Foundation

struct MultiAgentDrainActiveTurn: Equatable, Hashable, Sendable {
    let threadID: String
    let turnID: String
}

enum MultiAgentDrainBlockReason: Equatable, Hashable, Sendable {
    case missingRootThread(String)
    case duplicateThreadDetails([String])
    case nodeLimitExceeded(limit: Int, observed: Int)
    case missingThreadDetails([String])
    case conflictingParents(threadID: String, parentThreadIDs: [String])
    case cycle([String])
    case unreachableFromRoot([String])
    case multipleActiveTurns(threadID: String, turnIDs: [String])
    case unknownTurnStatus(threadID: String, turnID: String, status: String)
    case unknownThreadStatus(threadID: String, status: String)
    case unloadedThreadWithoutHistory(String)

    var description: String {
        switch self {
        case let .missingRootThread(threadID):
            "Missing root thread detail: \(threadID)"
        case let .duplicateThreadDetails(threadIDs):
            "Duplicate thread details: \(threadIDs.joined(separator: ", "))"
        case let .nodeLimitExceeded(limit, observed):
            "Agent graph contains \(observed) nodes, exceeding the limit of \(limit)"
        case let .missingThreadDetails(threadIDs):
            "Missing thread details: \(threadIDs.joined(separator: ", "))"
        case let .conflictingParents(threadID, parentThreadIDs):
            "Thread \(threadID) has conflicting parents: \(parentThreadIDs.joined(separator: ", "))"
        case let .cycle(threadIDs):
            "Agent graph contains a cycle: \(threadIDs.joined(separator: ", "))"
        case let .unreachableFromRoot(threadIDs):
            "Threads cannot be traced to the root: \(threadIDs.joined(separator: ", "))"
        case let .multipleActiveTurns(threadID, turnIDs):
            "Thread \(threadID) has multiple active turns: \(turnIDs.joined(separator: ", "))"
        case let .unknownTurnStatus(threadID, turnID, status):
            "Thread \(threadID) turn \(turnID) has unknown status: \(status)"
        case let .unknownThreadStatus(threadID, status):
            "Thread \(threadID) has unknown status: \(status)"
        case let .unloadedThreadWithoutHistory(threadID):
            "Thread \(threadID) is not loaded and has no terminal history"
        }
    }
}

struct MultiAgentDrainSnapshot: Equatable, Sendable {
    let rootThreadID: String
    let observedThreadIDs: [String]
    let parentByThreadID: [String: String]
    let activeTurns: [MultiAgentDrainActiveTurn]
    let pendingThreadIDs: [String]
    let terminalThreadIDs: [String]
    let blockers: [MultiAgentDrainBlockReason]
    let stabilitySignature: String

    var blockedReason: MultiAgentDrainBlockReason? { blockers.first }

    var isDrained: Bool {
        blockers.isEmpty
            && activeTurns.isEmpty
            && pendingThreadIDs.isEmpty
            && Set(terminalThreadIDs) == Set(observedThreadIDs)
    }
}

/// Builds and classifies one authoritative snapshot of a Codex multi-agent tree.
///
/// This type deliberately performs no network calls, polling, sleeping, or
/// interruption. Its caller owns reconciliation cadence and persists the known
/// thread IDs between observations.
struct MultiAgentDrainCoordinator: Sendable {
    let maximumNodeCount: Int

    init(maximumNodeCount: Int = 128) {
        self.maximumNodeCount = max(1, maximumNodeCount)
    }

    func makeSnapshot(
        rootThreadID: String,
        threadDetails: [CodexThreadDetail],
        knownThreadIDs: Set<String> = []
    ) -> MultiAgentDrainSnapshot {
        var blockers: [MultiAgentDrainBlockReason] = []
        var detailsByID: [String: CodexThreadDetail] = [:]
        var duplicateThreadIDs = Set<String>()

        for detail in threadDetails {
            if detailsByID.updateValue(detail, forKey: detail.summary.id) != nil {
                duplicateThreadIDs.insert(detail.summary.id)
            }
        }
        if !duplicateThreadIDs.isEmpty {
            blockers.append(.duplicateThreadDetails(duplicateThreadIDs.sorted()))
        }

        var observedThreadIDs = knownThreadIDs
        observedThreadIDs.insert(rootThreadID)
        observedThreadIDs.formUnion(detailsByID.keys)

        var authoritativeParents: [String: Set<String>] = [:]
        var spawnParents: [String: Set<String>] = [:]
        for detail in threadDetails {
            let detailThreadID = detail.summary.id
            if detailThreadID != rootThreadID,
               let rawParentThreadID = detail.summary.parentThreadID {
                let parentThreadID = rawParentThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !parentThreadID.isEmpty else { continue }
                authoritativeParents[detailThreadID, default: []].insert(parentThreadID)
                observedThreadIDs.insert(parentThreadID)
            }

            for turn in detail.turns {
                for item in turn.items {
                    if let activity = item.subAgentActivity {
                        observedThreadIDs.insert(activity.agentThreadID)
                    }
                    guard let collaboration = item.collaboration else { continue }
                    let senderThreadID = collaboration.senderThreadID
                    observedThreadIDs.insert(senderThreadID)
                    for receiverThreadID in collaboration.receiverThreadIDs {
                        observedThreadIDs.insert(receiverThreadID)
                        guard collaboration.tool == "spawnAgent",
                              receiverThreadID != rootThreadID
                        else { continue }
                        spawnParents[receiverThreadID, default: []].insert(senderThreadID)
                    }
                }
            }
        }

        if observedThreadIDs.count > maximumNodeCount {
            blockers.append(.nodeLimitExceeded(
                limit: maximumNodeCount,
                observed: observedThreadIDs.count
            ))
        }
        if detailsByID[rootThreadID] == nil {
            blockers.append(.missingRootThread(rootThreadID))
        }

        let missingThreadIDs = observedThreadIDs
            .subtracting(Set(detailsByID.keys))
            .sorted()
        if !missingThreadIDs.isEmpty {
            blockers.append(.missingThreadDetails(missingThreadIDs))
        }

        var parentByThreadID: [String: String] = [:]
        let threadsWithParentEvidence = Set(authoritativeParents.keys)
            .union(spawnParents.keys)
        for threadID in threadsWithParentEvidence.sorted() where threadID != rootThreadID {
            let authoritative = authoritativeParents[threadID, default: []].sorted()
            let spawned = spawnParents[threadID, default: []].sorted()
            if authoritative.count > 1 {
                blockers.append(.conflictingParents(
                    threadID: threadID,
                    parentThreadIDs: Set(authoritative + spawned).sorted()
                ))
                continue
            }
            if let authoritativeParent = authoritative.first {
                parentByThreadID[threadID] = authoritativeParent
                let conflicting = spawned.filter { $0 != authoritativeParent }
                if !conflicting.isEmpty {
                    blockers.append(.conflictingParents(
                        threadID: threadID,
                        parentThreadIDs: Set([authoritativeParent] + conflicting).sorted()
                    ))
                }
            } else if spawned.count == 1, let spawnedParent = spawned.first {
                parentByThreadID[threadID] = spawnedParent
            } else if spawned.count > 1 {
                blockers.append(.conflictingParents(
                    threadID: threadID,
                    parentThreadIDs: spawned
                ))
            }
        }

        if let cycle = firstCycle(
            rootThreadID: rootThreadID,
            observedThreadIDs: observedThreadIDs,
            parentByThreadID: parentByThreadID
        ) {
            blockers.append(.cycle(cycle))
        }

        let presentThreadIDs = Set(detailsByID.keys)
        let unreachableThreadIDs = presentThreadIDs
            .filter { threadID in
                threadID != rootThreadID
                    && !reachesRoot(
                        threadID: threadID,
                        rootThreadID: rootThreadID,
                        parentByThreadID: parentByThreadID
                    )
            }
            .sorted()
        if !unreachableThreadIDs.isEmpty {
            blockers.append(.unreachableFromRoot(unreachableThreadIDs))
        }

        var activeTurns: [MultiAgentDrainActiveTurn] = []
        var pendingThreadIDs: [String] = []
        var terminalThreadIDs: [String] = []
        for threadID in detailsByID.keys.sorted() {
            guard let detail = detailsByID[threadID] else { continue }
            let classification = classify(detail: detail)
            activeTurns.append(contentsOf: classification.activeTurns)
            if classification.isPending {
                pendingThreadIDs.append(threadID)
            }
            if classification.isTerminal {
                terminalThreadIDs.append(threadID)
            }
            blockers.append(contentsOf: classification.blockers)
        }
        activeTurns.sort {
            if $0.threadID == $1.threadID { return $0.turnID < $1.turnID }
            return $0.threadID < $1.threadID
        }

        let observed = observedThreadIDs.sorted()
        let signature = stabilitySignature(
            rootThreadID: rootThreadID,
            observedThreadIDs: observed,
            parentByThreadID: parentByThreadID,
            activeTurns: activeTurns,
            pendingThreadIDs: pendingThreadIDs,
            terminalThreadIDs: terminalThreadIDs,
            blockers: blockers
        )
        return MultiAgentDrainSnapshot(
            rootThreadID: rootThreadID,
            observedThreadIDs: observed,
            parentByThreadID: parentByThreadID,
            activeTurns: activeTurns,
            pendingThreadIDs: pendingThreadIDs,
            terminalThreadIDs: terminalThreadIDs,
            blockers: blockers,
            stabilitySignature: signature
        )
    }

    private func classify(detail: CodexThreadDetail) -> ThreadClassification {
        let threadID = detail.summary.id
        var blockers: [MultiAgentDrainBlockReason] = []
        var activeTurnIDs: [String] = []

        for turn in detail.turns {
            switch Self.normalizedStatus(turn.status) {
            case "inprogress":
                activeTurnIDs.append(turn.id)
            case "completed", "interrupted", "failed":
                break
            default:
                blockers.append(.unknownTurnStatus(
                    threadID: threadID,
                    turnID: turn.id,
                    status: turn.status
                ))
            }
        }
        activeTurnIDs.sort()
        if activeTurnIDs.count > 1 {
            blockers.append(.multipleActiveTurns(
                threadID: threadID,
                turnIDs: activeTurnIDs
            ))
        }

        let activeTurns = activeTurnIDs.map {
            MultiAgentDrainActiveTurn(threadID: threadID, turnID: $0)
        }
        if !activeTurns.isEmpty {
            return ThreadClassification(
                activeTurns: activeTurns,
                isPending: false,
                isTerminal: false,
                blockers: blockers
            )
        }
        guard blockers.isEmpty else {
            return ThreadClassification(
                activeTurns: [],
                isPending: false,
                isTerminal: false,
                blockers: blockers
            )
        }

        switch Self.normalizedStatus(detail.summary.statusType) {
        case "active":
            return ThreadClassification(
                activeTurns: [],
                isPending: true,
                isTerminal: false,
                blockers: []
            )
        case "idle", "systemerror":
            return ThreadClassification(
                activeTurns: [],
                isPending: false,
                isTerminal: true,
                blockers: []
            )
        case "notloaded" where !detail.turns.isEmpty:
            return ThreadClassification(
                activeTurns: [],
                isPending: false,
                isTerminal: true,
                blockers: []
            )
        case "notloaded":
            return ThreadClassification(
                activeTurns: [],
                isPending: false,
                isTerminal: false,
                blockers: [.unloadedThreadWithoutHistory(threadID)]
            )
        default:
            return ThreadClassification(
                activeTurns: [],
                isPending: false,
                isTerminal: false,
                blockers: [.unknownThreadStatus(
                    threadID: threadID,
                    status: detail.summary.statusType
                )]
            )
        }
    }

    private func firstCycle(
        rootThreadID: String,
        observedThreadIDs: Set<String>,
        parentByThreadID: [String: String]
    ) -> [String]? {
        for startThreadID in observedThreadIDs.sorted() where startThreadID != rootThreadID {
            var path: [String] = []
            var positionByThreadID: [String: Int] = [:]
            var currentThreadID: String? = startThreadID
            while let threadID = currentThreadID, threadID != rootThreadID {
                if let cycleStart = positionByThreadID[threadID] {
                    return Array(path[cycleStart...]).sorted()
                }
                positionByThreadID[threadID] = path.count
                path.append(threadID)
                currentThreadID = parentByThreadID[threadID]
            }
        }
        return nil
    }

    private func reachesRoot(
        threadID: String,
        rootThreadID: String,
        parentByThreadID: [String: String]
    ) -> Bool {
        var visited = Set<String>()
        var currentThreadID = threadID
        while currentThreadID != rootThreadID {
            guard visited.insert(currentThreadID).inserted,
                  let parentThreadID = parentByThreadID[currentThreadID]
            else { return false }
            currentThreadID = parentThreadID
        }
        return true
    }

    private func stabilitySignature(
        rootThreadID: String,
        observedThreadIDs: [String],
        parentByThreadID: [String: String],
        activeTurns: [MultiAgentDrainActiveTurn],
        pendingThreadIDs: [String],
        terminalThreadIDs: [String],
        blockers: [MultiAgentDrainBlockReason]
    ) -> String {
        var components = ["root=\(Self.lengthPrefixed(rootThreadID))"]
        components.append("nodes=\(observedThreadIDs.map(Self.lengthPrefixed).joined(separator: ","))")
        let edges = parentByThreadID.keys.sorted().map { threadID in
            let parentThreadID = parentByThreadID[threadID] ?? ""
            return "\(Self.lengthPrefixed(threadID))>\(Self.lengthPrefixed(parentThreadID))"
        }
        components.append("edges=\(edges.joined(separator: ","))")
        let active = activeTurns.map { activeTurn in
            "\(Self.lengthPrefixed(activeTurn.threadID))@\(Self.lengthPrefixed(activeTurn.turnID))"
        }
        components.append("active=\(active.joined(separator: ","))")
        components.append("pending=\(pendingThreadIDs.map(Self.lengthPrefixed).joined(separator: ","))")
        components.append("terminal=\(terminalThreadIDs.map(Self.lengthPrefixed).joined(separator: ","))")
        components.append("blocked=\(blockers.map { Self.lengthPrefixed($0.description) }.joined(separator: ","))")
        return components.joined(separator: "|")
    }

    private static func normalizedStatus(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

private struct ThreadClassification {
    let activeTurns: [MultiAgentDrainActiveTurn]
    let isPending: Bool
    let isTerminal: Bool
    let blockers: [MultiAgentDrainBlockReason]
}
