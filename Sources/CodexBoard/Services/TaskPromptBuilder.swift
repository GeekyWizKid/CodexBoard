import Foundation

enum TaskPromptBuilder {
    static func planningPrompt(for task: BoardTask, projectPath: String) -> String {
        """
        你正在为 CodexBoard 进行一次独立的规划轮次。只分析和规划，不要修改、创建或删除任何文件，也不要执行会改变项目状态的命令。

        项目目录：\(projectPath)
        来源类型：\(task.sourceKind.title)
        任务标题：\(task.title)

        原始输入：
        \(task.sourceText)
        \(attachmentSection(for: task))

        请检查仓库中与任务相关的代码、文档、测试和约束，然后输出一份可以直接交给下一轮执行的中文 Markdown 方案。方案应包含：目标与验收标准、关键现状、逐步实施计划、风险/假设、验证方式。不要向用户提问；信息不足时请做保守且明确的假设并写入方案。不要声称已经实施。
        """
    }

    static func executionPrompt(for task: BoardTask, projectPath: String) -> String {
        """
        下面的方案已经在 CodexBoard 中确认。现在请在指定项目内完整实施，持续工作到验证结束；不要再次停下来请求方案确认。

        项目目录：\(projectPath)
        任务标题：\(task.title)
        来源类型：\(task.sourceKind.title)

        原始输入：
        \(task.sourceText)
        \(attachmentSection(for: task))

        已确认方案：
        \(task.planText)
        \(reviewFeedbackSection(for: task))

        要求：保护用户已有改动和数据；把修改限制在当前项目；完成与风险相称的测试/构建/界面验证；如果客观阻塞，保留现场并在最终结果中给出准确错误与下一步。

        最终回复先用中文总结实际完成内容、验证结果和仍存在的问题，然后必须在末尾附加下面格式的机器可读交付证据。字段不可省略；没有对应内容时使用空字符串、空数组或 null。JSON 必须有效，不要在 JSON 中写 Markdown：

        ```codexboard-evidence
        {
          "summary": "本次实际完成内容的简明摘要",
          "changedFiles": ["相对项目目录的文件路径"],
          "verificationCommands": ["实际执行过的测试、构建或检查命令"],
          "testSummary": "验证结果摘要；未运行时明确说明原因",
          "commitSHA": null,
          "pullRequestURL": null,
          "residualRisks": ["尚未验证或仍需人工判断的风险"]
        }
        ```
        """
    }

    static func planningInput(for task: BoardTask, projectPath: String) -> [CodexTurnInput] {
        turnInput(text: planningPrompt(for: task, projectPath: projectPath), attachments: task.attachments)
    }

    static func executionInput(for task: BoardTask, projectPath: String) -> [CodexTurnInput] {
        turnInput(text: executionPrompt(for: task, projectPath: projectPath), attachments: task.attachments)
    }

    private static func attachmentSection(for task: BoardTask) -> String {
        guard !task.attachments.isEmpty else { return "" }
        let lines = task.attachments.map { attachment in
            "- \(attachment.kind.title)：\(attachment.displayName) — \(attachment.path)"
        }
        return """

        附件：
        \(lines.joined(separator: "\n"))

        附件只作为本任务的输入资料；可以读取其内容，但不要修改、移动或删除附件源文件。
        """
    }

    private static func reviewFeedbackSection(for task: BoardTask) -> String {
        guard let feedback = task.reviewFeedback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feedback.isEmpty
        else { return "" }
        return """

        上一轮验收要求修改：
        \(feedback)

        本轮必须针对以上反馈进行修正，并重新执行相关验证。
        """
    }

    private static func turnInput(
        text: String,
        attachments: [TaskAttachment]
    ) -> [CodexTurnInput] {
        [.text(text)] + attachments.compactMap { attachment in
            guard attachment.kind == .image else { return nil }
            return .localImage(path: attachment.path)
        }
    }
}
