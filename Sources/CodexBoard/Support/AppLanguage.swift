import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L10n.text("language.system", fallback: "Follow System")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }

    static var selected: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var activeLocalizationCode: String {
        switch selected {
        case .simplifiedChinese:
            "zh-Hans"
        case .english:
            "en"
        case .system:
            Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
                ? "zh-Hans"
                : "en"
        }
    }
}

enum L10n {
    static var locale: Locale {
        Locale(identifier: AppLanguage.activeLocalizationCode)
    }

    static func text(_ key: String, fallback: String) -> String {
        guard let path = Bundle.main.path(
            forResource: AppLanguage.activeLocalizationCode,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return fallback
        }
        return bundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback: fallback), locale: locale, arguments: arguments)
    }

    static func localizedRuntimeText(_ value: String) -> String {
        guard AppLanguage.activeLocalizationCode == "en" else { return value }
        let replacements: [String: String] = [
            "正在连接本机 Codex…": "Connecting to local Codex…",
            "正在扫描本机 Codex 项目…": "Scanning local Codex projects…",
            "等待开始规划": "Waiting to start planning",
            "开始只读规划。": "Started read-only planning.",
            "Codex 正在检查项目并制定方案…": "Codex is inspecting the project and drafting a plan…",
            "方案完成，等待确认": "Plan ready, awaiting approval",
            "方案已生成，等待确认。": "Plan ready, awaiting approval.",
            "方案已确认，等待执行槽位。": "Plan approved, waiting for an execution slot.",
            "正在准备执行…": "Preparing execution…",
            "开始执行已确认方案。": "Executing the approved plan.",
            "Codex 正在实施方案…": "Codex is implementing the plan…",
            "执行完成，等待验收": "Execution complete, awaiting review",
            "Codex 已完成实施，等待检查交付证据。": "Implementation complete; review the delivery evidence.",
            "交付证据已验收，任务完成。": "Delivery accepted; task completed.",
            "已熔断，等待人工处理": "Circuit open; waiting for manual action",
            "请求状态不确定，已暂停以避免重复执行": "Request state is uncertain; paused to avoid duplicate execution"
        ]
        if let replacement = replacements[value] {
            return replacement
        }
        if value.hasPrefix("已载入 "), value.hasSuffix(" 个项目") {
            let count = value.dropFirst(4).dropLast(4)
            return "Loaded \(count) projects"
        }
        if value.hasPrefix("等待 "), value.hasSuffix(" 个前置任务验收") {
            let count = value.dropFirst(3).dropLast(9)
            return "Waiting for \(count) dependencies"
        }
        return value
    }
}
