import SwiftUI

struct LiveTaskComposer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var live: LiveTaskComposerStore

    private let hostName: String

    init(boardStore: BoardStore, project: ProjectRecord) {
        hostName = boardStore.hostName(for: project.hostID)
        _live = StateObject(wrappedValue: LiveTaskComposerStore(
            projectID: project.id,
            projectName: project.name,
            createTask: { projectID, title, sourceKind, sourceText, autoRun in
                boardStore.createLiveTask(
                    projectID: projectID,
                    title: title,
                    sourceKind: sourceKind,
                    sourceText: sourceText,
                    autoRun: autoRun
                )
            }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    projectCard

                    if canConfigure {
                        credentialCard
                    } else {
                        conversationCard
                    }

                    if !live.drafts.isEmpty {
                        draftSection
                    }

                    if !live.createdTaskIDs.isEmpty {
                        successCard
                    }

                    if let error = live.lastError, !error.isEmpty {
                        errorCard(error)
                    }
                }
                .padding(22)
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 760)
        .onDisappear {
            Task { await live.stop() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(BoardTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("GPT Live 创建任务")
                    .font(.title2.weight(.semibold))
                Text("对话澄清需求，确认草稿后才进入看板待办。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .padding(22)
    }

    private var statusBadge: some View {
        Label(live.state.displayTitle, systemImage: statusSymbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(statusColor)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var projectCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(BoardTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.projectName)
                    .font(.headline)
                Label(hostName, systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("会话期间固定", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private var credentialCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                SecureField("OpenAI Platform API key（已保存时可留空）", text: $live.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()

                HStack {
                    Toggle("保存到本机 macOS 钥匙串", isOn: $live.rememberAPIKey)
                    Spacer()
                    Picker("声音", selection: $live.voice) {
                        ForEach(["marin", "cedar", "cove", "coral", "alloy"], id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                    .frame(width: 190)
                }

                Label(
                    "普通 Codex 任务继续使用现有登录；API key 只注入专用 Live 子进程，不会写入看板数据或 Codex auth.json。",
                    systemImage: "key.horizontal.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Link(
                        "在 OpenAI Platform 管理 API key",
                        destination: URL(string: "https://platform.openai.com/api-keys")!
                    )
                    .font(.caption)
                    if live.hasStoredAPIKey {
                        Button("删除已保存密钥", role: .destructive) {
                            live.deleteSavedAPIKey()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button {
                        Task { await live.start() }
                    } label: {
                        Label("开始 Live 对话", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BoardTheme.accent)
                    .disabled(live.state.isBusy)
                }
            }
            .padding(4)
        } label: {
            Label("Realtime 连接", systemImage: "bolt.horizontal.circle")
        }
    }

    private var conversationCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                transcriptView
                Divider()
                conversationControls
            }
            .padding(4)
        } label: {
            HStack {
                Label("需求对话", systemImage: "quote.bubble")
                Spacer()
                if live.droppedAudioChunkCount > 0 {
                    Label("网络较慢，已丢弃旧音频", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(BoardTheme.approval)
                }
            }
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if live.transcript.isEmpty, live.liveTranscript.isEmpty {
                        ContentUnavailableView(
                            "开始描述任务",
                            systemImage: "mic",
                            description: Text("可以按下麦克风说话，也可以在下方输入文字。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    }
                    ForEach(live.transcript) { entry in
                        transcriptBubble(entry)
                    }
                    if !live.liveTranscript.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(live.liveTranscript)
                                .foregroundStyle(.secondary)
                        }
                        .id("live-transcript")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 250)
            .onChange(of: live.transcript.count) { _, _ in
                if let last = live.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func transcriptBubble(_ entry: LiveTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(roleLabel(entry.role))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.text)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            entry.role == "user" ? BoardTheme.accent.opacity(0.12) : Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .frame(maxWidth: .infinity, alignment: entry.role == "user" ? .trailing : .leading)
        .id(entry.id)
    }

    private var conversationControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task { await live.toggleMicrophone() }
                } label: {
                    Label(
                        live.isMicrophoneEnabled ? "停止说话" : "开始说话",
                        systemImage: live.isMicrophoneEnabled ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(minWidth: 94)
                }
                .buttonStyle(.borderedProminent)
                .tint(live.isMicrophoneEnabled ? BoardTheme.danger : BoardTheme.accent)
                .disabled(!canTalk)

                TextField("也可以输入补充信息…", text: $live.textInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await live.sendText() } }
                    .disabled(!canTalk)

                Button {
                    Task { await live.sendText() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(.title2)
                .disabled(!canTalk || live.textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送文字")
            }

            HStack {
                Label("Live 只能提交草稿，不能直接执行", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await live.requestDrafts() }
                } label: {
                    Label("生成任务草稿", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!canTalk || live.state == .requestingDrafts)
            }
        }
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("待确认草稿", systemImage: "checklist")
                    .font(.headline)
                Text("\(live.drafts.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(BoardTheme.approval, in: Capsule())
                Spacer()
                Button("全部丢弃", role: .destructive) { live.discardDrafts() }
                    .buttonStyle(.borderless)
                Button("全部确认创建") { _ = live.confirmAllDrafts() }
                    .buttonStyle(.borderedProminent)
                    .tint(BoardTheme.completed)
            }

            ForEach(live.drafts) { draft in
                draftEditor(draft)
            }
        }
    }

    private func draftEditor(_ draft: LiveTaskDraft) -> some View {
        let isConfirmed = live.confirmedTaskID(for: draft.id) != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("任务标题", text: draftBinding(draft, keyPath: \.title))
                    .font(.headline)
                    .disabled(isConfirmed)
                Picker("类型", selection: draftBinding(draft, keyPath: \.sourceKind)) {
                    ForEach(TaskSourceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(isConfirmed)
            }

            TextEditor(text: draftBinding(draft, keyPath: \.sourceText))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 92)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .disabled(isConfirmed)

            HStack {
                Text("确认后创建到待办，等待你在看板中开始只读规划。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isConfirmed {
                    Label("已创建", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(BoardTheme.completed)
                } else {
                    Button("删除", role: .destructive) { live.removeDraft(id: draft.id) }
                        .buttonStyle(.borderless)
                    Button("确认创建") { _ = live.confirmDraft(id: draft.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(BoardTheme.accent)
                        .disabled(
                            draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private var successCard: some View {
        Label(
            "已创建 \(live.createdTaskIDs.count) 个任务，正在看板待办中等待开始规划。",
            systemImage: "checkmark.circle.fill"
        )
        .font(.headline)
        .foregroundStyle(BoardTheme.completed)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BoardTheme.completed.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(BoardTheme.danger)
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BoardTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Text("GPT Live / App Server 实验接口")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if live.isLive {
                Button("结束 Live") { Task { await live.stop() } }
            }
            Button(live.createdTaskIDs.isEmpty ? "取消" : "完成") {
                Task {
                    if live.createdTaskIDs.isEmpty {
                        await live.cancel()
                    } else {
                        await live.stop()
                    }
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var canConfigure: Bool {
        switch live.state {
        case .idle, .connecting, .startingThread, .startingRealtime, .closed, .failed:
            true
        case .live, .requestingDrafts, .reviewing, .stopping:
            false
        }
    }

    private var canTalk: Bool {
        switch live.state {
        case .live, .reviewing:
            true
        default:
            false
        }
    }

    private var statusSymbol: String {
        switch live.state {
        case .idle, .closed: "circle"
        case .connecting, .startingThread, .startingRealtime, .stopping: "progress.indicator"
        case .live: "waveform"
        case .requestingDrafts: "sparkles"
        case .reviewing: "checklist"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch live.state {
        case .live: BoardTheme.executing
        case .requestingDrafts, .reviewing: BoardTheme.approval
        case .failed: BoardTheme.danger
        default: .secondary
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": "你"
        case "assistant": "GPT Live"
        case "developer": "系统"
        default: role
        }
    }

    private func draftBinding<Value>(
        _ draft: LiveTaskDraft,
        keyPath: WritableKeyPath<LiveTaskDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                live.drafts.first(where: { $0.id == draft.id })?[keyPath: keyPath]
                    ?? draft[keyPath: keyPath]
            },
            set: { value in
                guard var updated = live.drafts.first(where: { $0.id == draft.id }) else { return }
                updated[keyPath: keyPath] = value
                live.updateDraft(updated)
            }
        )
    }
}
