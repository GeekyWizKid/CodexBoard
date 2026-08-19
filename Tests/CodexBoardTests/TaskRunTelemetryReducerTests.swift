import XCTest
@testable import CodexBoard

final class TaskRunTelemetryReducerTests: XCTestCase {
    func testLifecycleEventsMergeByStableProtocolIdentityEvenWhenCompletedArrivesFirst() {
        let reducer = TaskRunTelemetryReducer()
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 120)
        let id = TaskRunTelemetryReducer.activityID(
            sourceThreadID: "root:1",
            sourceTurnID: "turn|1",
            protocolItemID: "activity:1"
        )
        var telemetry = reducer.recording(
            TaskRunAgentActivity(
                id: id,
                protocolItemID: "activity:1",
                sourceThreadID: "root:1",
                sourceTurnID: "turn|1",
                agentThreadID: "completed-payload-child",
                agentPath: "/completed/payload",
                kind: "completedPayloadKind",
                completedAt: completedAt
            ),
            in: nil
        )
        telemetry = reducer.recording(
            TaskRunAgentActivity(
                id: id,
                protocolItemID: "activity:1",
                sourceThreadID: "root:1",
                sourceTurnID: "turn|1",
                agentThreadID: "child-1",
                agentPath: "/root/child",
                kind: "unknownFutureKind",
                startedAt: startedAt
            ),
            in: telemetry
        )
        telemetry = reducer.recording(
            TaskRunAgentActivity(
                id: id,
                protocolItemID: "activity:1",
                sourceThreadID: "root:1",
                sourceTurnID: "turn|1",
                agentThreadID: "conflicting-child",
                agentPath: "/conflicting/path",
                kind: "conflictingKind",
                completedAt: completedAt.addingTimeInterval(1)
            ),
            in: telemetry
        )

        XCTAssertEqual(telemetry.agentActivities.count, 1)
        XCTAssertEqual(telemetry.agentActivities[0].kind, "unknownFutureKind")
        XCTAssertEqual(telemetry.agentActivities[0].agentThreadID, "child-1")
        XCTAssertEqual(telemetry.agentActivities[0].agentPath, "/root/child")
        XCTAssertEqual(telemetry.agentActivities[0].startedAt, startedAt)
        XCTAssertEqual(
            telemetry.agentActivities[0].completedAt,
            completedAt.addingTimeInterval(1)
        )
    }

    func testAgentActivityHistoryKeepsLatestBoundedEntriesInStableOrder() {
        let reducer = TaskRunTelemetryReducer()
        var telemetry: TaskRunTelemetry?
        for offset in 0...TaskRunTelemetryReducer.maximumAgentActivityCount {
            let value = String(offset)
            telemetry = reducer.recording(
                TaskRunAgentActivity(
                    id: value,
                    protocolItemID: value,
                    sourceThreadID: "root",
                    sourceTurnID: "turn",
                    agentThreadID: "child-\(value)",
                    agentPath: "/root/child-\(value)",
                    kind: "interacted",
                    startedAt: Date(timeIntervalSince1970: TimeInterval(offset))
                ),
                in: telemetry
            )
        }

        let activities = telemetry?.agentActivities ?? []
        XCTAssertEqual(activities.count, TaskRunTelemetryReducer.maximumAgentActivityCount)
        XCTAssertEqual(activities.first?.protocolItemID, "1")
        XCTAssertEqual(activities.last?.protocolItemID, "100")
    }

    func testTokenUsageReplacesLatestThreadSnapshotWithoutAddingCounters() {
        let reducer = TaskRunTelemetryReducer()
        let first = usage(threadID: "root", turnID: "turn-1", totalTokens: 100, receivedAt: 1)
        let replacement = usage(
            threadID: "root",
            turnID: "turn-1",
            totalTokens: 140,
            receivedAt: 2
        )
        var telemetry = reducer.recording(first, in: nil)
        telemetry = reducer.recording(replacement, in: telemetry)

        XCTAssertEqual(telemetry.tokenUsageByThread.count, 1)
        XCTAssertEqual(telemetry.tokenUsageByThread[0].total.totalTokens, 140)
        XCTAssertEqual(telemetry.tokenUsageByThread[0].last.totalTokens, 14)
    }

    func testTaskCardDoesNotProjectTelemetryFromAnOlderRunOntoANewerAttempt() {
        let oldRun = TaskRun(
            phase: .planning,
            attempt: 1,
            outcome: .completed,
            threadID: "root",
            reasoningEffort: .medium,
            fastMode: false,
            telemetry: TaskRunTelemetry(
                agentActivities: [TaskRunAgentActivity(
                    protocolItemID: "activity",
                    sourceThreadID: "root",
                    sourceTurnID: "turn-1",
                    agentThreadID: "child",
                    agentPath: "/root/child",
                    kind: "interacted",
                    startedAt: Date(timeIntervalSince1970: 1)
                )],
                tokenUsageByThread: [usage(
                    threadID: "root",
                    turnID: "turn-1",
                    totalTokens: 100,
                    receivedAt: 1
                )]
            )
        )
        let newRun = TaskRun(
            phase: .execution,
            attempt: 1,
            threadID: "root",
            reasoningEffort: .medium,
            fastMode: false
        )
        let card = BoardTaskCard(task: BoardTask(
            projectID: "/tmp/project",
            title: "New attempt",
            sourceKind: .issue,
            sourceText: "Do not show stale telemetry",
            stage: .executing,
            autoRun: false,
            runs: [oldRun, newRun]
        ))

        XCTAssertNil(card.latestAgentActivityKind)
        XCTAssertNil(card.latestAgentPath)
        XCTAssertNil(card.rootThreadTotalTokens)
    }

    private func usage(
        threadID: String,
        turnID: String,
        totalTokens: Int64,
        receivedAt: TimeInterval
    ) -> TaskRunThreadTokenUsageSnapshot {
        TaskRunThreadTokenUsageSnapshot(
            threadID: threadID,
            turnID: turnID,
            receivedAt: Date(timeIntervalSince1970: receivedAt),
            total: TaskRunTokenUsageBreakdown(
                totalTokens: totalTokens,
                inputTokens: totalTokens - 20,
                cachedInputTokens: 10,
                cacheWriteInputTokens: 2,
                outputTokens: 15,
                reasoningOutputTokens: 5
            ),
            last: TaskRunTokenUsageBreakdown(
                totalTokens: totalTokens / 10,
                inputTokens: totalTokens / 10 - 2,
                cachedInputTokens: 1,
                cacheWriteInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 1
            ),
            modelContextWindow: 200_000
        )
    }
}
