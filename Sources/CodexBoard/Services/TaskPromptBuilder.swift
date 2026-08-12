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

        已确认方案：
        \(task.planText)

        要求：保护用户已有改动和数据；把修改限制在当前项目；完成与风险相称的测试/构建/界面验证；如果客观阻塞，保留现场并在最终结果中给出准确错误与下一步。最后用中文总结实际完成内容、验证结果和仍存在的问题。
        """
    }
}
