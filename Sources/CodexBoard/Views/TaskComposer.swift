import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var attachments: [TaskAttachmentDraft] = []
    @State private var submissionError: String?
    @State private var isSubmitting = false

    init(store: BoardStore, isPresented: Binding<Bool>) {
        self.store = store
        _isPresented = isPresented
        _projectID = State(initialValue: store.selectedProjectID ?? store.visibleProjects.first?.id ?? "")
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
                    Text("先生成只读方案，再确认执行。")
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

                codexOptionsEditor

                VStack(alignment: .leading, spacing: 6) {
                    Text(sourceKind == .issue ? "Issue 内容" : "开发计划")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $sourceText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 145)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            if sourceText.isEmpty {
                                Text(sourceKind == .issue
                                     ? "粘贴 GitHub Issue、缺陷描述或需求…"
                                     : "输入里程碑、功能清单、约束与验收标准…")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                attachmentEditor

                Toggle(isOn: $autoRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全自动模式")
                        Text("规划完成后跳过方案确认并自动进入执行队列；不会扩大项目写入权限。")
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
                Button("创建并规划") {
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
        .frame(width: 640, height: 700)
        .onAppear {
            synchronizeModelSelection(selectDefaultWhenEmpty: true)
        }
        .task {
            if store.availableModels.isEmpty && !store.isLoadingModels {
                await store.refreshModels()
            }
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
            ? "获得更快响应，但会增加用量。"
            : "所选模型不提供 Fast 服务层级。"
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

    private var attachmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("附件")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    chooseFiles()
                } label: {
                    Label("添加文件…", systemImage: "paperclip")
                }
                Button {
                    pasteScreenshot()
                } label: {
                    Label("粘贴截图", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            if attachments.isEmpty {
                Text("可添加多个本地文件，或从剪贴板粘贴截图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            attachmentRow(attachment)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func attachmentRow(_ attachment: TaskAttachmentDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: draftSymbol(attachment))
                .foregroundStyle(BoardTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .lineLimit(1)
                Text(attachment.byteCount.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "大小未知")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除附件")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .help(draftPath(attachment) ?? attachment.displayName)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "添加任务附件"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let existingPaths = Set(attachments.compactMap(draftPath))
        let newDrafts = panel.urls
            .map(TaskAttachmentDraft.file)
            .filter { draft in
                guard let path = draftPath(draft) else { return true }
                return !existingPaths.contains(path)
                    && !attachments.contains(where: { draftPath($0) == path })
            }
        attachments.append(contentsOf: newDrafts)
        submissionError = nil
    }

    private func pasteScreenshot() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            submissionError = "剪贴板中没有可用的图片。"
            return
        }
        let number = attachments.count { draft in
            if case .pastedImage = draft.source { return true }
            return false
        } + 1
        attachments.append(TaskAttachmentDraft(
            displayName: "剪贴板截图 \(number).png",
            byteCount: Int64(pngData.count),
            source: .pastedImage(pngData)
        ))
        submissionError = nil
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
                    fastMode: fastMode
                )
                isPresented = false
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }

    private func draftPath(_ draft: TaskAttachmentDraft) -> String? {
        guard case let .file(url) = draft.source else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func draftSymbol(_ draft: TaskAttachmentDraft) -> String {
        switch draft.source {
        case .pastedImage:
            return "photo"
        case let .file(url):
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
                return "doc"
            }
            return "photo"
        }
    }
}
