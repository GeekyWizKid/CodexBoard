import Foundation

struct TaskRunTelemetryReducer: Sendable {
    static let maximumAgentActivityCount = 100
    static let maximumTokenThreadCount = 128

    static func activityID(
        sourceThreadID: String,
        sourceTurnID: String,
        protocolItemID: String
    ) -> String {
        TaskRunAgentActivity.stableID(
            sourceThreadID: sourceThreadID,
            sourceTurnID: sourceTurnID,
            protocolItemID: protocolItemID
        )
    }

    func recording(
        _ activity: TaskRunAgentActivity,
        in telemetry: TaskRunTelemetry?
    ) -> TaskRunTelemetry {
        var result = telemetry ?? TaskRunTelemetry()
        if let index = result.agentActivities.firstIndex(where: { $0.id == activity.id }) {
            let existing = result.agentActivities[index]
            let canonical: TaskRunAgentActivity
            if let incomingStartedAt = activity.startedAt {
                if let existingStartedAt = existing.startedAt,
                   existingStartedAt <= incomingStartedAt {
                    canonical = existing
                } else {
                    canonical = activity
                }
            } else {
                canonical = existing
            }
            result.agentActivities[index] = TaskRunAgentActivity(
                id: canonical.id,
                protocolItemID: canonical.protocolItemID,
                sourceThreadID: canonical.sourceThreadID,
                sourceTurnID: canonical.sourceTurnID,
                agentThreadID: canonical.agentThreadID,
                agentPath: canonical.agentPath,
                kind: canonical.kind,
                startedAt: earliest(existing.startedAt, activity.startedAt),
                completedAt: latest(existing.completedAt, activity.completedAt)
            )
        } else {
            result.agentActivities.append(activity)
        }
        result.agentActivities.sort(by: activitySortOrder)
        if result.agentActivities.count > Self.maximumAgentActivityCount {
            result.agentActivities.removeFirst(
                result.agentActivities.count - Self.maximumAgentActivityCount
            )
        }
        return result
    }

    func recording(
        _ usage: TaskRunThreadTokenUsageSnapshot,
        in telemetry: TaskRunTelemetry?
    ) -> TaskRunTelemetry {
        var result = telemetry ?? TaskRunTelemetry()
        if let index = result.tokenUsageByThread.firstIndex(where: {
            $0.threadID == usage.threadID
        }) {
            result.tokenUsageByThread[index] = usage
        } else {
            result.tokenUsageByThread.append(usage)
        }
        result.tokenUsageByThread.sort { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
            return lhs.threadID < rhs.threadID
        }
        if result.tokenUsageByThread.count > Self.maximumTokenThreadCount {
            result.tokenUsageByThread.removeFirst(
                result.tokenUsageByThread.count - Self.maximumTokenThreadCount
            )
        }
        return result
    }

    private func activitySortOrder(
        _ lhs: TaskRunAgentActivity,
        _ rhs: TaskRunAgentActivity
    ) -> Bool {
        let lhsDate = lhs.startedAt ?? lhs.completedAt ?? .distantPast
        let rhsDate = rhs.startedAt ?? rhs.completedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    private func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}
