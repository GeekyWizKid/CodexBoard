import Foundation

enum TaskPromptBuilder {
    enum PathSemantics: Sendable {
        case local
        case remote
    }

    static func planningPrompt(
        for task: BoardTask,
        projectPath: String,
        dependencies: [TaskDependencyHandoff] = []
    ) -> String {
        """
        你正在为 CodexBoard 进行一次独立的规划轮次。只分析和规划，不要修改、创建或删除任何文件，也不要执行会改变项目状态的命令。

        项目目录：\(projectPath)
        来源类型：\(task.sourceKind.title)
        任务标题：\(task.title)

        原始输入：
        \(task.sourceText)
        \(attachmentSection(for: task))
        \(dependencySection(dependencies))
        \(capabilitySection(for: task, planningOnly: true))

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
        \(capabilitySection(for: task, planningOnly: false))

        已确认方案：
        \(task.planText)
        \(reviewFeedbackSection(for: task))

        要求：保护用户已有改动和数据；把修改限制在当前项目；完成与风险相称的测试/构建/界面验证；如果客观阻塞，保留现场并在最终结果中给出准确错误与下一步。

        最终回复先用中文总结实际完成内容、验证结果和仍存在的问题，然后必须在末尾附加下面格式的机器可读交付证据。字段不可省略；没有对应内容时使用空字符串、空数组或 null。JSON 必须有效，不要在 JSON 中写 Markdown：

        ```codexboard-evidence
        {
          "summary": "本次实际完成内容的简明摘要",
          "changedFiles": ["相对项目目录的文件路径"],
          "artifacts": [
            {"title": "可供用户打开或使用的交付物名称", "path": "相对项目目录的文件路径", "kind": "document|image|archive|data|other"}
          ],
          "verificationCommands": ["实际执行过的测试、构建或检查命令"],
          "testSummary": "验证结果摘要；未运行时明确说明原因",
          "commitSHA": null,
          "pullRequestURL": null,
          "residualRisks": ["尚未验证或仍需人工判断的风险"]
        }
        ```
        """
    }

    static func planningInput(
        for task: BoardTask,
        projectPath: String,
        dependencies: [TaskDependencyHandoff] = []
    ) -> [CodexTurnInput] {
        turnInput(
            text: planningPrompt(for: task, projectPath: projectPath, dependencies: dependencies),
            skills: task.selectedSkills,
            apps: task.selectedApps.filter { !$0.requiresApproval },
            attachments: task.attachments
        )
    }

    static func executionInput(
        for task: BoardTask,
        projectPath: String,
        sourceProjectPath: String? = nil,
        pathSemantics: PathSemantics = .local
    ) -> [CodexTurnInput] {
        let sourceProjectPath = sourceProjectPath ?? projectPath
        let skills = task.selectedSkills.map { skill in
            TaskSkillSelection(
                name: skill.name,
                description: skill.description,
                path: executionSkillPath(
                    skill.path,
                    sourceProjectPath: sourceProjectPath,
                    executionPath: projectPath,
                    pathSemantics: pathSemantics
                ),
                scope: skill.scope
            )
        }
        return turnInput(
            text: executionPrompt(for: task, projectPath: projectPath),
            skills: skills,
            apps: task.selectedApps.filter { !$0.requiresApproval },
            attachments: task.attachments
        )
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

    private static func dependencySection(_ dependencies: [TaskDependencyHandoff]) -> String {
        guard !dependencies.isEmpty else { return "" }
        let handoffs = dependencies.map { dependency in
            var lines = [
                "- 前置任务：\(dependency.title)（\(dependency.id.uuidString)）",
                "  交付摘要：\(dependency.summary.isEmpty ? "未提供" : dependency.summary)"
            ]
            if !dependency.changedFiles.isEmpty {
                lines.append("  变更文件：\(dependency.changedFiles.joined(separator: "、"))")
            }
            if !dependency.testSummary.isEmpty {
                lines.append("  验证：\(dependency.testSummary)")
            }
            if let commitSHA = dependency.commitSHA {
                lines.append("  Commit：\(commitSHA)")
            }
            if let pullRequestURL = dependency.pullRequestURL {
                lines.append("  PR：\(pullRequestURL)")
            }
            return lines.joined(separator: "\n")
        }
        return """

        已验收的前置任务交接信息：
        \(handoffs.joined(separator: "\n"))

        请把以上交付视为当前任务的上游上下文；仍需以仓库实际状态为准，不要重复实现已完成内容。
        """
    }

    private static func capabilitySection(for task: BoardTask, planningOnly: Bool) -> String {
        guard !task.selectedSkills.isEmpty || !task.selectedApps.isEmpty else { return "" }
        var sections: [String] = []
        if !task.selectedSkills.isEmpty {
            let lines = task.selectedSkills.map { skill in
                let description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return description.isEmpty
                    ? "- \(skill.name)（\(skill.scope)）"
                    : "- \(skill.name)（\(skill.scope)）：\(description)"
            }
            sections.append("已选 Skills：\n\(lines.joined(separator: "\n"))")
        }
        if !task.selectedApps.isEmpty {
            let lines = task.selectedApps.map { app in
                let description = app.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let availability = app.requiresApproval
                    ? "（已阻止：包含写入工具）"
                    : "（规划和执行阶段可用）"
                return description.isEmpty
                    ? "- \(app.name)\(availability)"
                    : "- \(app.name)\(availability)：\(description)"
            }
            var appSection = "已选 Apps：\n\(lines.joined(separator: "\n"))"
            if planningOnly {
                appSection += """

                标记为“已阻止”的 App 不会注入任何 Turn，不得调用。其余 App 在规划阶段也只允许调用标记为只读的工具；不得通过 App 创建、修改或删除任何外部数据。
                """
            } else if task.selectedApps.contains(where: \.requiresApproval) {
                appSection += """

                标记为“已阻止”的 App 不会注入本轮，不得调用。当前版本仅开放全部已启用工具均为只读的 App。
                """
            }
            sections.append(appSection)
        }
        return """

        已为本任务选择的能力：
        \(sections.joined(separator: "\n\n"))
        """
    }

    private static func turnInput(
        text: String,
        skills: [TaskSkillSelection],
        apps: [TaskAppSelection],
        attachments: [TaskAttachment]
    ) -> [CodexTurnInput] {
        let skillInputs = skills.map { skill in
            CodexTurnInput.skill(name: skill.name, path: skill.path)
        }
        let appInputs = apps.map { app in
            let invocationName = app.invocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexTurnInput.mention(
                name: invocationName.isEmpty ? app.name : invocationName,
                path: "app://\(app.id)"
            )
        }
        let imageInputs: [CodexTurnInput] = attachments.compactMap { attachment in
            guard attachment.kind == .image else { return nil }
            return .localImage(path: attachment.path)
        }
        return [.text(text)] + skillInputs + appInputs + imageInputs
    }

    private static func executionSkillPath(
        _ skillPath: String,
        sourceProjectPath: String,
        executionPath: String,
        pathSemantics: PathSemantics
    ) -> String {
        guard (skillPath as NSString).isAbsolutePath else { return skillPath }
        if pathSemantics == .remote {
            return remoteExecutionSkillPath(
                skillPath,
                sourceProjectPath: sourceProjectPath,
                executionPath: executionPath
            )
        }
        let sourceRoot = URL(fileURLWithPath: sourceProjectPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executionRoot = URL(fileURLWithPath: executionPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard sourceRoot.path != executionRoot.path else { return skillPath }

        let sourceSkill = URL(fileURLWithPath: skillPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = sourceRoot.pathComponents
        let skillComponents = sourceSkill.pathComponents
        guard skillComponents.count > rootComponents.count,
              skillComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return skillPath }

        let relativeComponents = skillComponents.dropFirst(rootComponents.count)
        let candidate = relativeComponents.reduce(executionRoot) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path) else { return skillPath }
        return candidate.path
    }

    private static func remoteExecutionSkillPath(
        _ skillPath: String,
        sourceProjectPath: String,
        executionPath: String
    ) -> String {
        let sourceRoot = (sourceProjectPath as NSString).standardizingPath
        let executionRoot = (executionPath as NSString).standardizingPath
        let sourceSkill = (skillPath as NSString).standardizingPath
        guard (sourceRoot as NSString).isAbsolutePath,
              (executionRoot as NSString).isAbsolutePath,
              (sourceSkill as NSString).isAbsolutePath,
              sourceRoot != executionRoot
        else { return skillPath }

        let rootComponents = (sourceRoot as NSString).pathComponents
        let skillComponents = (sourceSkill as NSString).pathComponents
        guard skillComponents.count > rootComponents.count,
              skillComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return skillPath }

        let relativeComponents = skillComponents.dropFirst(rootComponents.count)
        return relativeComponents.reduce(executionRoot) { partial, component in
            (partial as NSString).appendingPathComponent(component)
        }
    }
}
