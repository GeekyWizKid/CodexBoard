import UserNotifications
import XCTest
@testable import CodexBoard

@MainActor
final class TaskNotificationServiceTests: XCTestCase {
    func testForegroundPresentationOnlyUsesBannerListAndSoundForAttentionCategory() {
        XCTAssertEqual(
            TaskNotificationService.presentationOptions(
                for: TaskNotificationConstants.categoryIdentifier
            ),
            [.banner, .list, .sound]
        )
        XCTAssertEqual(
            TaskNotificationService.presentationOptions(for: "another.category"),
            []
        )
    }

    func testNotificationActivationRequiresDefaultActionCategoryAndValidTaskID() {
        let taskID = UUID()
        let userInfo: [AnyHashable: Any] = [
            TaskNotificationConstants.taskIDUserInfoKey: taskID.uuidString
        ]

        XCTAssertEqual(
            TaskNotificationService.activatedTaskID(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                categoryIdentifier: TaskNotificationConstants.categoryIdentifier,
                userInfo: userInfo
            ),
            taskID
        )
        XCTAssertNil(TaskNotificationService.activatedTaskID(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            categoryIdentifier: TaskNotificationConstants.categoryIdentifier,
            userInfo: userInfo
        ))
        XCTAssertNil(TaskNotificationService.activatedTaskID(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: "another.category",
            userInfo: userInfo
        ))
        XCTAssertNil(TaskNotificationService.activatedTaskID(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: TaskNotificationConstants.categoryIdentifier,
            userInfo: [TaskNotificationConstants.taskIDUserInfoKey: "not-a-uuid"]
        ))
    }

    func testNotificationContentContainsOnlyGenericCopyAndTaskIdentifier() {
        let taskID = UUID()
        let notice = TaskAttentionNotice(
            id: UUID(),
            taskID: taskID,
            kind: .interaction,
            createdAt: Date()
        )

        let content = TaskNotificationService.notificationContent(for: notice)

        XCTAssertEqual(
            content.title,
            L10n.text("notification.attention.title", fallback: "CodexBoard Needs Your Attention")
        )
        XCTAssertEqual(
            content.body,
            L10n.text(
                "notification.attention.interaction",
                fallback: "A task is waiting for your response. Open CodexBoard to review it."
            )
        )
        XCTAssertEqual(content.categoryIdentifier, TaskNotificationConstants.categoryIdentifier)
        XCTAssertEqual(content.userInfo.count, 1)
        XCTAssertEqual(
            content.userInfo[TaskNotificationConstants.taskIDUserInfoKey] as? String,
            taskID.uuidString
        )
    }

    func testFailureNotificationUsesGenericCopyAndOnlyTaskIdentifier() {
        let taskID = UUID()
        let notice = TaskAttentionNotice(
            id: UUID(),
            taskID: taskID,
            kind: .failure,
            createdAt: Date()
        )

        let content = TaskNotificationService.notificationContent(for: notice)

        XCTAssertEqual(
            content.body,
            L10n.text(
                "notification.attention.failure",
                fallback: "A task needs manual attention. Open CodexBoard to review it."
            )
        )
        XCTAssertFalse(content.body.contains("super-secret-answer"))
        XCTAssertFalse(content.body.contains("/Users/private/worktree"))
        XCTAssertEqual(content.userInfo.count, 1)
        XCTAssertEqual(
            content.userInfo[TaskNotificationConstants.taskIDUserInfoKey] as? String,
            taskID.uuidString
        )
    }
}
