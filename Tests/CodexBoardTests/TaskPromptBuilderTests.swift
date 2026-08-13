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
        XCTAssertTrue(prompt.contains("```codexboard-evidence"))
        XCTAssertTrue(prompt.contains("\"changedFiles\""))
        XCTAssertTrue(prompt.contains("\"verificationCommands\""))
    }

    func testExecutionPromptCarriesReviewFeedbackIntoNextAttempt() {
        var task = BoardTask(
            projectID: "/tmp/project",
            title: "Review iteration",
            sourceKind: .issue,
            sourceText: "Fix the implementation",
            autoRun: false
        )
        task.planText = "Implement the change"
        task.reviewFeedback = "补充失败路径测试。"

        let prompt = TaskPromptBuilder.executionPrompt(for: task, projectPath: "/tmp/project")

        XCTAssertTrue(prompt.contains("上一轮验收要求修改"))
        XCTAssertTrue(prompt.contains("补充失败路径测试。"))
        XCTAssertTrue(prompt.contains("本轮必须针对以上反馈进行修正"))
    }

    func testDeliveryEvidenceParserKeepsHumanResultSeparateFromMachineBlock() {
        let result = """
        已完成实现并通过测试。

        ```codexboard-evidence
        {
          "summary": "实现完成",
          "changedFiles": ["Sources/Feature.swift"],
          "verificationCommands": ["swift test"],
          "testSummary": "通过",
          "commitSHA": null,
          "pullRequestURL": null,
          "residualRisks": []
        }
        ```
        """

        let evidence = TaskDeliveryEvidenceParser.parse(from: result)

        XCTAssertEqual(evidence.summary, "实现完成")
        XCTAssertEqual(evidence.changedFiles, ["Sources/Feature.swift"])
        XCTAssertEqual(
            TaskDeliveryEvidenceParser.humanReadableResult(from: result),
            "已完成实现并通过测试。"
        )
    }

    func testAttachmentsAreListedAndImagesBecomeStructuredInput() {
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "Inspect attachments",
            sourceKind: .issue,
            sourceText: "",
            attachments: [
                TaskAttachment(
                    kind: .file,
                    displayName: "requirements.pdf",
                    path: "/tmp/requirements.pdf"
                ),
                TaskAttachment(
                    kind: .image,
                    displayName: "screen.png",
                    path: "/tmp/screen.png"
                )
            ],
            autoRun: false
        )

        let input = TaskPromptBuilder.planningInput(for: task, projectPath: "/tmp/project")

        XCTAssertEqual(input.count, 2)
        guard case let .text(prompt) = input[0] else {
            return XCTFail("The first item must remain text")
        }
        XCTAssertTrue(prompt.contains("requirements.pdf — /tmp/requirements.pdf"))
        XCTAssertTrue(prompt.contains("screen.png — /tmp/screen.png"))
        XCTAssertTrue(prompt.contains("不要修改、移动或删除附件源文件"))
        XCTAssertEqual(input[1], .localImage(path: "/tmp/screen.png"))
        XCTAssertEqual(
            input[1].wireValue,
            .object(["type": .string("localImage"), "path": .string("/tmp/screen.png")])
        )
    }
}
