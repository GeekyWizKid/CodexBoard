import XCTest
@testable import CodexBoard

@MainActor
final class MultiAgentDrainCoordinatorTests: XCTestCase {
    func testBuildsGrandchildGraphFromParentThreadIDs() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(id: "child", parentThreadID: "root"),
                detail(id: "grandchild", parentThreadID: "child")
            ]
        )

        XCTAssertNil(snapshot.blockedReason)
        XCTAssertEqual(snapshot.parentByThreadID, [
            "child": "root",
            "grandchild": "child"
        ])
        XCTAssertEqual(snapshot.terminalThreadIDs, ["child", "grandchild", "root"])
        XCTAssertTrue(snapshot.isDrained)
    }

    func testCollaborationReceiverSuppliesMissingParentEdge() {
        let spawn = collaboration(
            senderThreadID: "root",
            receiverThreadIDs: ["child"]
        )
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root", items: [item(collaboration: spawn)]),
                detail(id: "child")
            ]
        )

        XCTAssertNil(snapshot.blockedReason)
        XCTAssertEqual(snapshot.parentByThreadID["child"], "root")
        XCTAssertTrue(snapshot.isDrained)
    }

    func testClassifiesExactActiveTurn() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(
                    id: "child",
                    parentThreadID: "root",
                    threadStatus: "active",
                    turnID: "child-turn",
                    turnStatus: "inProgress"
                )
            ]
        )

        XCTAssertNil(snapshot.blockedReason)
        XCTAssertEqual(snapshot.activeTurns, [MultiAgentDrainActiveTurn(
            threadID: "child",
            turnID: "child-turn"
        )])
        XCTAssertEqual(snapshot.terminalThreadIDs, ["root"])
        XCTAssertFalse(snapshot.isDrained)
    }

    func testTreatsBothCancellationSpellingsAsTerminal() {
        for status in ["cancelled", "canceled"] {
            let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
                rootThreadID: "root",
                threadDetails: [detail(
                    id: "root",
                    turnID: "cancelled-turn",
                    turnStatus: status
                )]
            )

            XCTAssertNil(snapshot.blockedReason, "status: \(status)")
            XCTAssertTrue(snapshot.isDrained, "status: \(status)")
        }
    }

    func testBlocksWhenKnownThreadDetailIsMissing() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [detail(id: "root")],
            knownThreadIDs: ["child"]
        )

        XCTAssertEqual(snapshot.blockedReason, .missingThreadDetails(["child"]))
        XCTAssertEqual(snapshot.observedThreadIDs, ["child", "root"])
        XCTAssertFalse(snapshot.isDrained)
    }

    func testDetectsCycle() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(id: "a", parentThreadID: "b"),
                detail(id: "b", parentThreadID: "a")
            ]
        )

        XCTAssertTrue(snapshot.blockers.contains(.cycle(["a", "b"])))
        XCTAssertTrue(snapshot.blockers.contains(.unreachableFromRoot(["a", "b"])))
        XCTAssertFalse(snapshot.isDrained)
    }

    func testDetectsConflictingParentEdges() {
        let alternateSpawn = collaboration(
            senderThreadID: "alternate-parent",
            receiverThreadIDs: ["child"]
        )
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root", items: [item(collaboration: alternateSpawn)]),
                detail(id: "alternate-parent", parentThreadID: "root"),
                detail(id: "child", parentThreadID: "root")
            ]
        )

        XCTAssertTrue(snapshot.blockers.contains(.conflictingParents(
            threadID: "child",
            parentThreadIDs: ["alternate-parent", "root"]
        )))
        XCTAssertEqual(snapshot.parentByThreadID["child"], "root")
        XCTAssertFalse(snapshot.isDrained)
    }

    func testSendInputDoesNotChangeAuthoritativeParentEdge() {
        let sendInput = collaboration(
            tool: "sendInput",
            senderThreadID: "alternate-agent",
            receiverThreadIDs: ["child"]
        )
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(
                    id: "alternate-agent",
                    parentThreadID: "root",
                    items: [item(collaboration: sendInput)]
                ),
                detail(id: "child", parentThreadID: "root")
            ]
        )

        XCTAssertNil(snapshot.blockedReason)
        XCTAssertEqual(snapshot.parentByThreadID["child"], "root")
        XCTAssertTrue(snapshot.isDrained)
    }

    func testSubAgentActivityWithoutDetailFailsClosedAsMissing() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [detail(
                id: "root",
                items: [activityItem(agentThreadID: "child")]
            )]
        )

        XCTAssertEqual(snapshot.observedThreadIDs, ["child", "root"])
        XCTAssertEqual(snapshot.blockedReason, .missingThreadDetails(["child"]))
        XCTAssertNil(snapshot.parentByThreadID["child"])
        XCTAssertFalse(snapshot.isDrained)
    }

    func testSubAgentActivityDoesNotInventParentEdge() {
        let snapshot = MultiAgentDrainCoordinator().makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(
                    id: "root",
                    items: [activityItem(agentThreadID: "child")]
                ),
                detail(id: "child")
            ]
        )

        XCTAssertEqual(snapshot.observedThreadIDs, ["child", "root"])
        XCTAssertTrue(snapshot.blockers.contains(.unreachableFromRoot(["child"])))
        XCTAssertNil(snapshot.parentByThreadID["child"])
        XCTAssertFalse(snapshot.isDrained)
    }

    func testDetectsUnreachableThreadAndNodeLimit() {
        let details = [
            detail(id: "root"),
            detail(id: "child", parentThreadID: "root"),
            detail(id: "orphan")
        ]
        let snapshot = MultiAgentDrainCoordinator(maximumNodeCount: 2).makeSnapshot(
            rootThreadID: "root",
            threadDetails: details
        )

        XCTAssertTrue(snapshot.blockers.contains(.nodeLimitExceeded(limit: 2, observed: 3)))
        XCTAssertTrue(snapshot.blockers.contains(.unreachableFromRoot(["orphan"])))
        XCTAssertFalse(snapshot.isDrained)
    }

    func testLateSpawnChangesStabilitySignature() {
        let coordinator = MultiAgentDrainCoordinator()
        let initial = coordinator.makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(id: "child", parentThreadID: "root")
            ]
        )
        let afterLateSpawn = coordinator.makeSnapshot(
            rootThreadID: "root",
            threadDetails: [
                detail(id: "root"),
                detail(id: "child", parentThreadID: "root"),
                detail(id: "late-child", parentThreadID: "child")
            ],
            knownThreadIDs: Set(initial.observedThreadIDs)
        )

        XCTAssertTrue(initial.isDrained)
        XCTAssertTrue(afterLateSpawn.isDrained)
        XCTAssertNotEqual(initial.stabilitySignature, afterLateSpawn.stabilitySignature)
        XCTAssertEqual(afterLateSpawn.observedThreadIDs, ["child", "late-child", "root"])
    }

    private func detail(
        id: String,
        parentThreadID: String? = nil,
        threadStatus: String = "idle",
        turnID: String = "completed-turn",
        turnStatus: String = "completed",
        items: [CodexThreadItem] = []
    ) -> CodexThreadDetail {
        CodexThreadDetail(
            summary: CodexThreadSummary(
                id: id,
                sessionID: "session-\(id)",
                cwd: "/project",
                name: id,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                isPinned: false,
                statusType: threadStatus,
                sourceKind: id == "root" ? "appServer" : "subAgent",
                parentThreadID: parentThreadID,
                agentNickname: nil,
                agentRole: nil
            ),
            turns: [CodexThreadTurn(
                id: turnID,
                status: turnStatus,
                items: items,
                error: nil,
                startedAt: nil,
                completedAt: nil,
                durationMilliseconds: nil
            )]
        )
    }

    private func item(collaboration: CodexCollabAgentToolCall) -> CodexThreadItem {
        CodexThreadItem(
            id: collaboration.id,
            type: "collabAgentToolCall",
            text: nil,
            status: collaboration.status,
            collaboration: collaboration
        )
    }

    private func activityItem(agentThreadID: String) -> CodexThreadItem {
        let activity = CodexSubAgentActivity(
            id: "activity-\(agentThreadID)",
            agentThreadID: agentThreadID,
            agentPath: "/root/\(agentThreadID)",
            kind: "started"
        )
        return CodexThreadItem(
            id: activity.id,
            type: "subAgentActivity",
            text: nil,
            status: nil,
            collaboration: nil,
            subAgentActivity: activity
        )
    }

    private func collaboration(
        tool: String = "spawnAgent",
        senderThreadID: String,
        receiverThreadIDs: [String]
    ) -> CodexCollabAgentToolCall {
        CodexCollabAgentToolCall(
            id: "collaboration-\(senderThreadID)",
            tool: tool,
            status: "completed",
            senderThreadID: senderThreadID,
            receiverThreadIDs: receiverThreadIDs,
            prompt: nil,
            model: nil,
            reasoningEffort: nil,
            agentStates: Dictionary(uniqueKeysWithValues: receiverThreadIDs.map {
                ($0, CodexCollabAgentState(status: "completed", message: nil))
            })
        )
    }
}
