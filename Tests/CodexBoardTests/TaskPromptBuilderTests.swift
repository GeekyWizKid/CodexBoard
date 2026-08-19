import XCTest
@testable import CodexBoard

final class TaskPromptBuilderTests: XCTestCase {
    func testPlanningPromptIncludesAcceptedDependencyHandoff() {
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "Downstream",
            sourceKind: .issue,
            sourceText: "Build on upstream",
            autoRun: false
        )
        let dependencyID = UUID()
        let prompt = TaskPromptBuilder.planningPrompt(
            for: task,
            projectPath: "/tmp/project",
            dependencies: [TaskDependencyHandoff(
                id: dependencyID,
                title: "Upstream",
                summary: "Added the API",
                changedFiles: ["Sources/API.swift"],
                testSummary: "Tests passed",
                commitSHA: "abc123",
                pullRequestURL: nil
            )]
        )

        XCTAssertTrue(prompt.contains("已验收的前置任务交接信息"))
        XCTAssertTrue(prompt.contains(dependencyID.uuidString))
        XCTAssertTrue(prompt.contains("Sources/API.swift"))
        XCTAssertTrue(prompt.contains("Tests passed"))
    }

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
        XCTAssertTrue(prompt.contains("\"artifacts\""))
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

    func testDeliveryEvidenceParserNormalizesArtifactMetadata() {
        let result = """
        已生成报告。

        ```codexboard-evidence
        {
          "summary": "生成交付报告",
          "changedFiles": [],
          "artifacts": [
            {"title": "  风险报告  ", "path": " reports/risk.pdf ", "kind": " document "},
            {"title": "重复", "path": "reports/risk.pdf", "kind": "document"},
            {"title": "", "path": "exports/data.csv", "kind": ""}
          ],
          "verificationCommands": [],
          "testSummary": "",
          "commitSHA": null,
          "pullRequestURL": null,
          "residualRisks": []
        }
        ```
        """

        let evidence = TaskDeliveryEvidenceParser.parse(from: result)

        XCTAssertEqual(evidence.artifacts, [
            TaskDeliveryArtifact(title: "风险报告", path: "reports/risk.pdf", kind: "document"),
            TaskDeliveryArtifact(title: "data.csv", path: "exports/data.csv", kind: "other")
        ])
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

    func testCapabilitiesBecomeStructuredTurnInputInStableOrder() {
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "Use capabilities",
            sourceKind: .issue,
            sourceText: "Inspect external context",
            selectedSkills: [TaskSkillSelection(
                name: "repo-audit",
                description: "Audit the repository",
                path: "/tmp/project/.agents/skills/repo-audit/SKILL.md",
                scope: "repo"
            )],
            selectedApps: [TaskAppSelection(
                id: "connector_readonly",
                name: "Read-only Connector",
                invocationName: "readonly",
                description: "Read external records"
            )],
            autoRun: false
        )

        let input = TaskPromptBuilder.planningInput(for: task, projectPath: "/tmp/project")

        XCTAssertEqual(input.count, 3)
        guard case let .text(prompt) = input[0] else {
            return XCTFail("The first item must remain text")
        }
        XCTAssertTrue(prompt.contains("已为本任务选择的能力"))
        XCTAssertTrue(prompt.contains("规划和执行阶段可用"))
        XCTAssertTrue(prompt.contains("规划阶段也只允许调用标记为只读的工具"))
        XCTAssertEqual(input[1], .skill(
            name: "repo-audit",
            path: "/tmp/project/.agents/skills/repo-audit/SKILL.md"
        ))
        XCTAssertEqual(input[2], .mention(name: "readonly", path: "app://connector_readonly"))
    }

    func testWriteCapableAppIsContextOnlyAndNeverInjected() {
        var task = BoardTask(
            projectID: "/tmp/project",
            title: "Use mixed apps",
            sourceKind: .issue,
            sourceText: "Read context, then update the external record",
            selectedApps: [
                TaskAppSelection(
                    id: "connector_readonly",
                    name: "Read-only Connector",
                    invocationName: "readonly",
                    description: "Reads external records"
                ),
                TaskAppSelection(
                    id: "connector_write",
                    name: "Write Connector",
                    invocationName: "writer",
                    description: "Updates external records",
                    requiresApproval: true
                )
            ],
            autoRun: false
        )
        task.planText = "Read the current record and apply the approved update."

        let planningInput = TaskPromptBuilder.planningInput(for: task, projectPath: "/tmp/project")
        let executionInput = TaskPromptBuilder.executionInput(for: task, projectPath: "/tmp/project")

        XCTAssertEqual(planningInput.count, 2)
        guard case let .text(planningPrompt) = planningInput[0] else {
            return XCTFail("The first planning item must remain text")
        }
        XCTAssertTrue(planningPrompt.contains("Write Connector（已阻止：包含写入工具）"))
        XCTAssertTrue(planningPrompt.contains("标记为“已阻止”的 App 不会注入任何 Turn"))
        XCTAssertEqual(
            planningInput[1],
            .mention(name: "readonly", path: "app://connector_readonly")
        )
        XCTAssertFalse(planningInput.contains(
            .mention(name: "writer", path: "app://connector_write")
        ))

        XCTAssertEqual(executionInput.count, 2)
        XCTAssertEqual(
            executionInput[1],
            .mention(name: "readonly", path: "app://connector_readonly")
        )
        XCTAssertFalse(executionInput.contains(
            .mention(name: "writer", path: "app://connector_write")
        ))
        guard case let .text(executionPrompt) = executionInput[0] else {
            return XCTFail("The first execution item must remain text")
        }
        XCTAssertTrue(executionPrompt.contains("标记为“已阻止”的 App 不会注入本轮"))
    }

    func testRemoteExecutionRemapsSkillPathsLexicallyWithoutUsingLocalFilesystemState() {
        let task = BoardTask(
            projectID: "ssh:worker:/srv/repo",
            title: "Use remote skills",
            sourceKind: .issue,
            sourceText: "Run remotely",
            selectedSkills: [
                TaskSkillSelection(
                    name: "inside",
                    description: "Inside the remote repository",
                    path: "/srv/repo/.agents/skills/inside/SKILL.md",
                    scope: "repo"
                ),
                TaskSkillSelection(
                    name: "sibling",
                    description: "Outside the remote repository",
                    path: "/srv/repo-other/SKILL.md",
                    scope: "user"
                )
            ],
            autoRun: false
        )

        let input = TaskPromptBuilder.executionInput(
            for: task,
            projectPath: "/srv/codexboard/worktrees/task",
            sourceProjectPath: "/srv/repo",
            pathSemantics: .remote
        )

        XCTAssertEqual(input[1], .skill(
            name: "inside",
            path: "/srv/codexboard/worktrees/task/.agents/skills/inside/SKILL.md"
        ))
        XCTAssertEqual(input[2], .skill(
            name: "sibling",
            path: "/srv/repo-other/SKILL.md"
        ))
    }
}
