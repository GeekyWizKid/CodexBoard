import AppKit
import SwiftUI

struct TaskComposer: View {
    let store: BoardStore
    @Binding var isPresented: Bool
    @State private var projectID: String
    @State private var title = ""
    @State private var sourceKind: TaskSourceKind = .issue
    @State private var sourceText = ""
    @State private var autoRun: Bool
    @State private var model: String
    @State private var effort: ReasoningEffort
    @State private var fastMode = false
    @State private var workspaceKind: TaskWorkspaceKind
    @State private var dependencyIDs = Set<UUID>()
    @State private var selectedSkillIDs = Set<String>()
    @State private var selectedAppIDs = Set<String>()
    @State private var attachments: [TaskAttachmentDraft] = []
    @State private var submissionError: String?
    @State private var isSubmitting = false

    init(store: BoardStore, isPresented: Binding<Bool>) {
        self.store = store
        _isPresented = isPresented
        let initialProjectID = store.selectedProjectID ?? store.visibleProjects.first?.id ?? ""
        _projectID = State(initialValue: initialProjectID)
        let initialProject = store.visibleProjects.first(where: { $0.id == initialProjectID })
        _workspaceKind = State(initialValue: initialProject?.isGitRepository == true ? .worktree : .project)
        _autoRun = State(initialValue: store.preferences.defaultAutoRun)
        let configuredModel = store.preferences.modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialModel: String
        if configuredModel.isEmpty {
            initialModel = store.defaultTaskModel?.model ?? ""
        } else {
            initialModel = store.availableModels.first {
                $0.model == configuredModel || $0.id == configuredModel
            }?.model ?? configuredModel
        }
        _model = State(initialValue: initialModel)
        _effort = State(initialValue: store.defaultTaskEffort(for: initialModel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("创建 Codex 任务")
                        .font(.title2.weight(.semibold))
                    Text(autoRun ? "创建后自动规划并执行。" : "创建后等待你手动开始规划。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Picker("项目", selection: $projectID) {
                    ForEach(store.visibleProjects) { project in
                        Text(project.name).tag(project.id)
                    }
                }

                Picker("输入类型", selection: $sourceKind) {
                    ForEach(TaskSourceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("标题（可留空自动提取）", text: $title)

                TaskWorkflowOptionsView(
                    store: store,
                    projectID: projectID,
                    workspaceKind: $workspaceKind,
                    dependencyIDs: $dependencyIDs
                )

                TaskCapabilitiesPicker(
                    store: store,
                    projectID: projectID,
                    selectedSkillIDs: $selectedSkillIDs,
                    selectedAppIDs: $selectedAppIDs
                )

                codexOptionsEditor

                TaskPromptInputView(
                    text: $sourceText,
                    attachments: $attachments,
                    label: sourceKind == .issue ? "Issue 内容" : "开发计划",
                    placeholder: sourceKind == .issue
                        ? "粘贴 GitHub Issue、缺陷描述或需求…"
                        : "输入里程碑、功能清单、约束与验收标准…",
                    chooseFiles: chooseFiles,
                    reportImportMessage: { submissionError = $0 }
                )

                Toggle(isOn: $autoRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全自动模式")
                        Text("开启后立即开始规划，并在方案完成后自动执行；关闭则在待办中等待手动开始。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("规划阶段强制只读", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let submissionError {
                        Text(submissionError)
                            .font(.caption)
                            .foregroundStyle(BoardTheme.danger)
                    }
                }
                Spacer()
                Button(submitButtonTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSubmitting
                        || projectID.isEmpty
                        || (sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && attachments.isEmpty)
                )
            }
        }
        .padding(22)
        .frame(width: 660, height: 780)
        .onAppear {
            synchronizeModelSelection(selectDefaultWhenEmpty: true)
        }
        .task {
            if store.availableModels.isEmpty && !store.isLoadingModels {
                await store.refreshModels()
            }
        }
        .task(id: projectID) {
            guard !projectID.isEmpty else { return }
            await store.refreshCapabilities(projectID: projectID)
        }
        .onChange(of: projectID) { _, _ in
            selectedSkillIDs.removeAll()
            selectedAppIDs.removeAll()
        }
        .onChange(of: model) { _, _ in
            synchronizeModelCapabilities()
        }
        .onChange(of: store.availableModels) { _, _ in
            synchronizeModelSelection(selectDefaultWhenEmpty: true)
        }
    }

    private var codexOptionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("模型", selection: $model) {
                if model.isEmpty {
                    Text("使用本机默认模型").tag("")
                } else if selectedModel == nil {
                    Text("自定义：\(model)").tag(model)
                }
                ForEach(store.availableModels) { availableModel in
                    Text(availableModel.displayName).tag(availableModel.model)
                }
            }

            Picker("推理强度（规划与执行）", selection: $effort) {
                ForEach(effortOptions, id: \.effort) { option in
                    Text(option.effort.title).tag(option.effort)
                }
            }

            Toggle(isOn: $fastMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast 模式")
                    Text(fastModeHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!supportsFast)

            if let selectedModel {
                Text(selectedModel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            modelCatalogStatus
        }
    }

    @ViewBuilder
    private var modelCatalogStatus: some View {
        if store.isLoadingModels && store.availableModels.isEmpty {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("正在载入本机 Codex 模型…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.modelCatalogError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
                    .lineLimit(2)
                Spacer()
                Button("重试") {
                    Task { await store.refreshModels() }
                }
                .controlSize(.small)
                .disabled(store.isLoadingModels)
            }
        }
    }

    private var selectedModel: CodexModel? {
        store.availableModels.first { $0.model == model || $0.id == model }
    }

    private var effortOptions: [CodexReasoningEffortOption] {
        if let selectedModel, !selectedModel.supportedReasoningEfforts.isEmpty {
            return selectedModel.supportedReasoningEfforts
        }
        var efforts = ReasoningEffort.standardCases
        if let defaultEffort = selectedModel?.defaultReasoningEffort,
           !efforts.contains(defaultEffort) {
            efforts.append(defaultEffort)
        }
        if !efforts.contains(effort) {
            efforts.append(effort)
        }
        return efforts.map {
            CodexReasoningEffortOption(effort: $0, description: "")
        }
    }

    private var supportsFast: Bool {
        selectedModel?.supportsFast == true
    }

    private var fastModeHelp: String {
        supportsFast
            ? L10n.text("获得更快响应，但会增加用量。", fallback: "获得更快响应，但会增加用量。")
            : L10n.text("所选模型不提供 Fast 服务层级。", fallback: "所选模型不提供 Fast 服务层级。")
    }

    private func synchronizeModelSelection(selectDefaultWhenEmpty: Bool) {
        if selectDefaultWhenEmpty, model.isEmpty, let defaultModel = store.defaultTaskModel {
            model = defaultModel.model
        } else if let selectedModel, model != selectedModel.model {
            model = selectedModel.model
        }
        synchronizeModelCapabilities()
    }

    private func synchronizeModelCapabilities() {
        guard let selectedModel else {
            fastMode = false
            return
        }
        if !selectedModel.supportedReasoningEfforts.contains(where: { $0.effort == effort }) {
            effort = store.defaultTaskEffort(for: selectedModel.model)
        }
        if !selectedModel.supportsFast {
            fastMode = false
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("添加任务附件", fallback: "添加任务附件")
        panel.prompt = L10n.text("添加", fallback: "添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let outcome = TaskAttachmentDraftImporter.importFiles(panel.urls, existing: attachments)
        attachments.append(contentsOf: outcome.drafts)
        submissionError = outcome.message
    }

    private func submit() {
        isSubmitting = true
        submissionError = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await store.createTask(
                    projectID: projectID,
                    title: title,
                    sourceKind: sourceKind,
                    sourceText: sourceText,
                    attachmentDrafts: attachments,
                    autoRun: autoRun,
                    model: model.isEmpty ? nil : model,
                    effort: effort,
                    fastMode: fastMode,
                    selectedSkills: frozenSkillSelections,
                    selectedApps: frozenAppSelections,
                    workspaceKind: workspaceKind,
                    dependencyIDs: store.dependencyCandidates(for: projectID)
                        .map(\.id)
                        .filter(dependencyIDs.contains)
                )
                isPresented = false
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }

    private var frozenSkillSelections: [TaskSkillSelection] {
        store.availableSkills.compactMap { skill in
            guard skill.enabled, selectedSkillIDs.contains(skill.id) else { return nil }
            return TaskSkillSelection(
                name: skill.name,
                description: skill.description,
                path: skill.path,
                scope: skill.scope
            )
        }
    }

    private var frozenAppSelections: [TaskAppSelection] {
        store.availableApps.compactMap { app in
            guard app.supportsReadOnlyUse,
                  selectedAppIDs.contains(app.id)
            else { return nil }
            return TaskAppSelection(
                id: app.id,
                name: app.name,
                invocationName: app.invocationName,
                description: app.description,
                requiresApproval: false
            )
        }
    }

    private var submitButtonTitle: String {
        let hasBlockingDependencies = store.dependencyCandidates(for: projectID).contains {
            dependencyIDs.contains($0.id) && $0.stage != .completed
        }
        if hasBlockingDependencies {
            return L10n.text("创建并等待", fallback: "创建并等待")
        }
        return autoRun
            ? L10n.text("创建并自动运行", fallback: "创建并自动运行")
            : L10n.text("创建任务", fallback: "创建任务")
    }

}
