import XCTest
@testable import CodexBoard

final class TaskPromptBuilderTests: XCTestCase {
    func testPlanningPromptEnforcesReadOnlyAndKeepsOriginalInput() {
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "修复登录",
            sourceKind: .issue,
            sourceText: "登录按钮点击后无响应",
            autoRun: false
        )

        let prompt = TaskPromptBuilder.planningPrompt(for: task, projectPath: "/tmp/project")

        XCTAssertTrue(prompt.contains("只分析和规划"))
        XCTAssertTrue(prompt.contains("不要修改、创建或删除任何文件"))
        XCTAssertTrue(prompt.contains("登录按钮点击后无响应"))
        XCTAssertTrue(prompt.contains("/tmp/project"))
    }

    func testExecutionPromptIncludesConfirmedPlanAndVerificationRequirement() {
        var task = BoardTask(
            projectID: "/tmp/project",
            title: "修复登录",
            sourceKind: .issue,
            sourceText: "登录按钮点击后无响应",
            autoRun: true
        )
        task.planText = "1. 修复状态绑定\n2. 增加测试"

        let prompt = TaskPromptBuilder.executionPrompt(for: task, projectPath: "/tmp/project")

        XCTAssertTrue(prompt.contains("方案已经在 CodexBoard 中确认"))
        XCTAssertTrue(prompt.contains("修复状态绑定"))
        XCTAssertTrue(prompt.contains("测试/构建/界面验证"))
        XCTAssertTrue(prompt.contains("保护用户已有改动和数据"))
    }
}
