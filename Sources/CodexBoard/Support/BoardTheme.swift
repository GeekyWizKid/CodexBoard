import SwiftUI

enum BoardTheme {
    static let accent = Color(red: 0.37, green: 0.40, blue: 0.96)
    static let planning = Color(red: 0.52, green: 0.37, blue: 0.95)
    static let approval = Color(red: 0.93, green: 0.58, blue: 0.16)
    static let executing = Color(red: 0.10, green: 0.63, blue: 0.71)
    static let review = Color(red: 0.22, green: 0.48, blue: 0.91)
    static let completed = Color(red: 0.18, green: 0.68, blue: 0.43)
    static let danger = Color(red: 0.88, green: 0.28, blue: 0.32)

    static func color(for stage: TaskStage) -> Color {
        switch stage {
        case .inbox: .secondary
        case .planning: planning
        case .awaitingApproval: approval
        case .executing: executing
        case .review: review
        case .completed: completed
        case .needsAttention: danger
        }
    }

    static func color(for outcome: TaskRunOutcome) -> Color {
        switch outcome {
        case .running: executing
        case .completed, .accepted: completed
        case .awaitingReview: review
        case .changesRequested: approval
        case .failed, .interrupted: danger
        }
    }
}

@MainActor
enum BoardFormatters {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "暂无活动" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
