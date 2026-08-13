import Foundation
@preconcurrency import UserNotifications

enum TaskNotificationConstants {
    static let categoryIdentifier = "com.local.CodexBoard.task-attention"
    static let requestIdentifierPrefix = "com.local.CodexBoard.task-attention."
    static let taskIDUserInfoKey = "taskID"
}

@MainActor
final class TaskNotificationService: NSObject {
    private enum AuthorizationState {
        case unknown
        case requesting
        case granted
        case denied
    }

    private let center: UNUserNotificationCenter
    private var desiredNotices: [UUID: TaskAttentionNotice] = [:]
    private var submittedNoticeIDs = Set<UUID>()
    private var authorizationState = AuthorizationState.unknown
    private var didReconcileExistingNotifications = false
    private var openTaskHandler: ((UUID) -> Void)?
    private var pendingTaskToOpen: UUID?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private let maxRetryAttempts = 3

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func setOpenTaskHandler(_ handler: @escaping (UUID) -> Void) {
        openTaskHandler = handler
        if let pendingTaskToOpen {
            self.pendingTaskToOpen = nil
            handler(pendingTaskToOpen)
        }
    }

    func synchronize(with notices: [TaskAttentionNotice]) {
        var nextNotices: [UUID: TaskAttentionNotice] = [:]
        for notice in notices {
            nextNotices[notice.id] = notice
        }

        let removedIDs = Set(desiredNotices.keys).subtracting(nextNotices.keys)
        desiredNotices = nextNotices

        if desiredNotices.isEmpty {
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
        }

        if !removedIDs.isEmpty {
            submittedNoticeIDs.subtract(removedIDs)
            removeNotifications(with: removedIDs)
        }

        if !didReconcileExistingNotifications {
            didReconcileExistingNotifications = true
            reconcileExistingNotifications()
        }

        guard !Set(desiredNotices.keys).subtracting(submittedNoticeIDs).isEmpty else { return }
        ensureAuthorization()
    }

    private func ensureAuthorization() {
        switch authorizationState {
        case .granted:
            submitDesiredNotifications()
        case .unknown:
            authorizationState = .requesting
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if failed {
                        self.authorizationState = .unknown
                        self.scheduleRetry()
                    } else {
                        self.authorizationState = granted ? .granted : .denied
                    }
                    if granted {
                        self.submitDesiredNotifications()
                    }
                }
            }
        case .requesting, .denied:
            break
        }
    }

    private func submitDesiredNotifications() {
        let pendingNotices = desiredNotices.values
            .filter { !submittedNoticeIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }

        for notice in pendingNotices {
            submittedNoticeIDs.insert(notice.id)

            let content = Self.notificationContent(for: notice)

            let request = UNNotificationRequest(
                identifier: requestIdentifier(for: notice.id),
                content: content,
                trigger: nil
            )
            center.add(request) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.desiredNotices[notice.id] != nil else {
                        self.submittedNoticeIDs.remove(notice.id)
                        self.removeNotifications(with: Set([notice.id]))
                        return
                    }
                    if error != nil {
                        self.submittedNoticeIDs.remove(notice.id)
                        self.scheduleRetry()
                    }
                }
            }
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .requesting = self.authorizationState,
                   status == .notDetermined {
                    return
                }
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.authorizationState = .granted
                    self.retryAttempt = 0
                    self.submitDesiredNotifications()
                case .denied:
                    self.authorizationState = .denied
                case .notDetermined:
                    self.authorizationState = .unknown
                    if !self.desiredNotices.isEmpty {
                        self.ensureAuthorization()
                    }
                @unknown default:
                    self.authorizationState = .unknown
                }
            }
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil,
              retryAttempt < maxRetryAttempts,
              !Set(desiredNotices.keys).subtracting(submittedNoticeIDs).isEmpty
        else { return }
        retryAttempt += 1
        let delay = retryAttempt
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard !self.desiredNotices.isEmpty else { return }
            self.ensureAuthorization()
        }
    }

    private func removeNotifications(with noticeIDs: Set<UUID>) {
        let identifiers = noticeIDs.map(requestIdentifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func reconcileExistingNotifications() {
        center.getPendingNotificationRequests { [weak self] requests in
            let identifiers = requests.compactMap { request in
                request.content.categoryIdentifier == TaskNotificationConstants.categoryIdentifier
                    ? request.identifier
                    : nil
            }
            Task { @MainActor [weak self] in
                self?.removeStalePendingNotifications(from: identifiers)
            }
        }

        center.getDeliveredNotifications { [weak self] notifications in
            let identifiers = notifications.compactMap { notification in
                notification.request.content.categoryIdentifier == TaskNotificationConstants.categoryIdentifier
                    ? notification.request.identifier
                    : nil
            }
            Task { @MainActor [weak self] in
                self?.removeStaleDeliveredNotifications(from: identifiers)
            }
        }
    }

    private func removeStalePendingNotifications(from identifiers: [String]) {
        let desiredIdentifiers = Set(desiredNotices.keys.map(requestIdentifier(for:)))
        let staleIdentifiers = identifiers.filter { !desiredIdentifiers.contains($0) }
        if !staleIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }
    }

    private func removeStaleDeliveredNotifications(from identifiers: [String]) {
        let desiredIdentifiers = Set(desiredNotices.keys.map(requestIdentifier(for:)))
        let staleIdentifiers = identifiers.filter { !desiredIdentifiers.contains($0) }
        if !staleIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: staleIdentifiers)
        }
    }

    private func requestIdentifier(for noticeID: UUID) -> String {
        "\(TaskNotificationConstants.requestIdentifierPrefix)\(noticeID.uuidString)"
    }

    static func notificationContent(
        for notice: TaskAttentionNotice
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.text(
            "notification.attention.title",
            fallback: "CodexBoard Needs Your Attention"
        )
        content.body = switch notice.kind {
        case .interaction:
            L10n.text(
                "notification.attention.interaction",
                fallback: "A task is waiting for your response. Open CodexBoard to review it."
            )
        case .planApproval:
            L10n.text(
                "notification.attention.plan",
                fallback: "A task plan is ready and waiting for approval."
            )
        }
        content.sound = .default
        content.categoryIdentifier = TaskNotificationConstants.categoryIdentifier
        content.userInfo = [
            TaskNotificationConstants.taskIDUserInfoKey: notice.taskID.uuidString
        ]
        return content
    }

    private func routeToTask(_ taskID: UUID) {
        guard let openTaskHandler else {
            pendingTaskToOpen = taskID
            return
        }
        openTaskHandler(taskID)
    }
}

extension TaskNotificationService: UNUserNotificationCenterDelegate {
    nonisolated static func presentationOptions(
        for categoryIdentifier: String
    ) -> UNNotificationPresentationOptions {
        categoryIdentifier == TaskNotificationConstants.categoryIdentifier
            ? [.banner, .list, .sound]
            : []
    }

    nonisolated static func activatedTaskID(
        actionIdentifier: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UUID? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              categoryIdentifier == TaskNotificationConstants.categoryIdentifier,
              let rawTaskID = userInfo[TaskNotificationConstants.taskIDUserInfoKey] as? String
        else { return nil }
        return UUID(uuidString: rawTaskID)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions(
            for: notification.request.content.categoryIdentifier
        ))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let taskID = Self.activatedTaskID(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) else { return }

        Task { @MainActor [weak self] in
            self?.routeToTask(taskID)
        }
    }
}
