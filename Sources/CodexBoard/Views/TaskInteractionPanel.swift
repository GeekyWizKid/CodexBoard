import SwiftUI

struct TaskInteractionPanel: View {
    let request: CodexInteractionRequest
    let isResponding: Bool
    let errorMessage: String?
    let respond: (CodexInteractionResponse) -> Void
    let openURL: (URL) -> Bool

    @State private var answers: [String: String] = [:]
    @State private var formJSON = "{}"
    @State private var localError: String?
    @State private var didOpenElicitationURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(panelTitle, systemImage: panelSymbol)
                    .font(.headline)
                    .foregroundStyle(BoardTheme.approval)
                Spacer()
                if isResponding {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在发送…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            interactionContent

            if let message = localError ?? errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BoardTheme.approval.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BoardTheme.approval.opacity(0.55), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var interactionContent: some View {
        switch request.kind {
        case let .commandApproval(approval):
            commandApproval(approval)
        case let .fileChangeApproval(approval):
            fileChangeApproval(approval)
        case let .userInput(input):
            userInput(input)
        case let .permissionsApproval(approval):
            permissionsApproval(approval)
        case let .mcpElicitation(elicitation):
            mcpElicitation(elicitation)
        }
    }

    private var panelTitle: String {
        switch request.kind {
        case .commandApproval: L10n.text("命令等待批准", fallback: "命令等待批准")
        case .fileChangeApproval: L10n.text("文件修改等待批准", fallback: "文件修改等待批准")
        case .userInput: L10n.text("Codex 需要补充信息", fallback: "Codex 需要补充信息")
        case .permissionsApproval: L10n.text("权限请求", fallback: "权限请求")
        case .mcpElicitation: L10n.text("外部服务请求", fallback: "外部服务请求")
        }
    }

    private var panelSymbol: String {
        switch request.kind {
        case .commandApproval: "terminal"
        case .fileChangeApproval: "doc.badge.gearshape"
        case .userInput: "questionmark.bubble"
        case .permissionsApproval: "lock.shield"
        case .mcpElicitation: "link"
        }
    }

    private func commandApproval(_ approval: CodexCommandApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = cleaned(approval.command) {
                interactionMetadata("命令", command, monospaced: true)
            }
            if let cwd = cleaned(approval.cwd) {
                interactionMetadata("目录", cwd, monospaced: true)
            }
            if let reason = cleaned(approval.reason) {
                interactionMetadata("原因", reason)
            }
            if let actions = approval.commandActions {
                jsonDisclosure("命令动作", value: actions)
            }
            if let permissions = approval.requestedPermissions {
                jsonDisclosure("请求权限", value: permissions)
            }
            if let networkContext = approval.networkApprovalContext {
                jsonDisclosure("网络访问", value: networkContext)
            }
            approvalButtons(available: approval.availableDecisions ?? legacyCommandDecisions(approval))
        }
    }

    private func fileChangeApproval(_ approval: CodexFileChangeApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = cleaned(approval.reason) {
                interactionMetadata("原因", reason)
            }
            if let root = cleaned(approval.grantRoot) {
                interactionMetadata("授权根目录", root, monospaced: true)
            }
            approvalButtons(available: [.accept, .acceptForSession, .decline, .cancel])
        }
    }

    private func permissionsApproval(_ approval: CodexPermissionsApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            interactionMetadata("目录", approval.cwd, monospaced: true)
            if let reason = cleaned(approval.reason) {
                interactionMetadata("原因", reason)
            }
            jsonBlock(title: "请求的精确权限", value: approval.permissions)

            HStack(spacing: 8) {
                Menu("允许…") {
                    Button("仅本轮允许") {
                        submit(.permissions(.grant(
                            permissions: approval.permissions,
                            scope: .turn
                        )))
                    }
                    Button("本任务内允许") {
                        submit(.permissions(.grant(
                            permissions: approval.permissions,
                            scope: .session
                        )))
                    }
                    Divider()
                    Button("本轮允许，但继续严格审核命令") {
                        submit(.permissions(.grant(
                            permissions: approval.permissions,
                            scope: .turn,
                            strictAutoReview: true
                        )))
                    }
                }
                .menuStyle(.borderedButton)

                Spacer()

                Button("拒绝") {
                    submit(.permissions(.deny(scope: .turn)))
                }
                .buttonStyle(.bordered)
            }
            .disabled(isResponding)

            Text("本任务内允许仅作用于当前 Codex 会话；不会修改全局设置。授予范围始终是上方精确权限。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func userInput(_ input: CodexUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(input.isBlocking ? "任务已暂停，等待你的回答。" : "Codex 请求以下补充信息。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(input.questions.prefix(3))) { question in
                questionEditor(question)
            }

            if input.questions.count > 3 {
                Label("当前面板最多处理 3 个问题，请取消本轮并缩小问题数量。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
            }

            HStack {
                Spacer()
                Button("提交回答") {
                    submit(.userInput(answerPayload(for: input)))
                }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.approval)
                .disabled(isResponding || !answersAreComplete(for: input) || input.questions.count > 3)
            }
        }
    }

    @ViewBuilder
    private func questionEditor(_ question: CodexUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.header)
                    .font(.callout.weight(.semibold))
                Text(question.question)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if question.isSecret {
                SecureField("必填", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResponding)
            } else if !question.isOther, let options = question.options, !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button {
                            answers[question.id] = option.label
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                if answers[question.id] == option.label {
                                    Image(systemName: "largecircle.fill.circle")
                                        .foregroundStyle(BoardTheme.approval)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isResponding)
                    }
                }
            } else {
                TextField("必填", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResponding)
            }
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mcpElicitation(_ elicitation: CodexMCPElicitation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            interactionMetadata("服务", elicitation.serverName)
            if !elicitation.message.isEmpty {
                Text(elicitation.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch elicitation.mode {
            case .url:
                urlElicitation(elicitation)
            case .form, .openAIForm:
                formElicitation(elicitation)
            }
        }
    }

    private func urlElicitation(_ elicitation: CodexMCPElicitation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let url = elicitation.url {
                LabeledContent("目标站点", value: url.host ?? "未知站点")
                    .font(.caption)
                Button {
                    openInBrowser(url)
                } label: {
                    Label("在浏览器打开", systemImage: "safari")
                }
                .disabled(isResponding || !isSafeWebURL(url))

                Button("我已完成，继续") {
                    submit(.mcpElicitation(.acceptURL))
                }
                .buttonStyle(.bordered)
                .disabled(isResponding || !didOpenElicitationURL)
            } else {
                Label("服务未提供有效链接。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
            }

            safeMCPButtons()
        }
    }

    private func formElicitation(_ elicitation: CodexMCPElicitation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let schema = elicitation.requestedSchema {
                jsonBlock(title: "表单 Schema", value: schema)
            }

            Text("响应 JSON")
                .font(.caption.weight(.semibold))
            TextEditor(text: $formJSON)
                .font(.caption.monospaced())
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 120)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .disabled(isResponding)

            if parsedFormObject == nil {
                Text("请输入有效 JSON 对象。")
                    .font(.caption2)
                    .foregroundStyle(BoardTheme.danger)
            }

            HStack {
                Button("接受并提交") {
                    guard let content = parsedFormObject else { return }
                    submit(.mcpElicitation(.accept(content: content, metadata: nil)))
                }
                .buttonStyle(.bordered)
                .disabled(isResponding || parsedFormObject == nil)

                Spacer()

                Button("拒绝") {
                    submit(.mcpElicitation(.decline))
                }
                .buttonStyle(.bordered)
                .disabled(isResponding)

                Button("取消") {
                    submit(.mcpElicitation(.cancel))
                }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.approval)
                .keyboardShortcut(.defaultAction)
                .disabled(isResponding)
            }
        }
    }

    private func safeMCPButtons() -> some View {
        HStack {
            Spacer()
            Button("拒绝") {
                submit(.mcpElicitation(.decline))
            }
            .buttonStyle(.bordered)
            .disabled(isResponding)

            Button("取消") {
                submit(.mcpElicitation(.cancel))
            }
            .buttonStyle(.borderedProminent)
            .tint(BoardTheme.approval)
            .keyboardShortcut(.defaultAction)
            .disabled(isResponding)
        }
    }

    private func approvalButtons(available: [CodexApprovalDecision]?) -> some View {
        let decisions = stableDecisions(available)
        return HStack {
            let approvals = decisions.filter(\.isApproval)
            if approvals.count == 1, let decision = approvals.first {
                decisionButton(decision)
            } else if !approvals.isEmpty {
                Menu("允许…") {
                    ForEach(approvals, id: \.self) { decision in
                        Button(decisionTitle(decision)) {
                            submit(.approval(decision))
                        }
                    }
                }
                .menuStyle(.borderedButton)
                .disabled(isResponding)
            }
            Spacer()
            ForEach(decisions.filter(\.isRejection), id: \.self) { decision in
                decisionButton(decision)
            }
        }
    }

    private func decisionButton(_ decision: CodexApprovalDecision) -> some View {
        Button(decisionTitle(decision)) {
            submit(.approval(decision))
        }
        .buttonStyle(.bordered)
        .disabled(isResponding)
    }

    private func stableDecisions(_ available: [CodexApprovalDecision]?) -> [CodexApprovalDecision] {
        let candidates: [CodexApprovalDecision]
        if let available, !available.isEmpty {
            candidates = available
        } else {
            candidates = [.accept, .decline, .cancel]
        }
        var seen = Set<CodexApprovalDecision>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func legacyCommandDecisions(_ approval: CodexCommandApproval) -> [CodexApprovalDecision] {
        if approval.networkApprovalContext != nil {
            var decisions: [CodexApprovalDecision] = [.accept, .acceptForSession]
            if let allowRule = approval.proposedNetworkPolicyAmendments.first(where: { $0.action == .allow }) {
                decisions.append(.applyNetworkPolicyAmendment(allowRule))
            }
            decisions.append(.cancel)
            return decisions
        }
        if approval.requestedPermissions != nil {
            return [.accept, .cancel]
        }
        var decisions: [CodexApprovalDecision] = [.accept]
        if let amendment = approval.proposedExecpolicyAmendment, !amendment.isEmpty {
            decisions.append(.acceptWithExecpolicyAmendment(amendment))
        }
        decisions.append(.cancel)
        return decisions
    }

    private func decisionTitle(_ decision: CodexApprovalDecision) -> String {
        switch decision {
        case .accept:
            L10n.text("仅本次允许", fallback: "仅本次允许")
        case .acceptForSession:
            switch request.kind {
            case .fileChangeApproval:
                L10n.text("本任务内允许修改这些文件", fallback: "本任务内允许修改这些文件")
            case let .commandApproval(approval) where approval.networkApprovalContext != nil:
                L10n.text("本任务内允许访问该主机", fallback: "本任务内允许访问该主机")
            case let .commandApproval(approval) where approval.requestedPermissions != nil:
                L10n.text("本任务内允许这些权限", fallback: "本任务内允许这些权限")
            default:
                L10n.text("本任务内不再询问这条命令", fallback: "本任务内不再询问这条命令")
            }
        case let .acceptWithExecpolicyAmendment(amendment):
            L10n.format(
                "approval.remember_command_prefix",
                fallback: "以后允许以 %@ 开头的命令",
                amendment.joined(separator: " ")
            )
        case let .applyNetworkPolicyAmendment(amendment):
            if amendment.action == .allow {
                L10n.format("approval.allow_host_future", fallback: "以后允许访问 %@", amendment.host)
            } else {
                L10n.format("approval.block_host_future", fallback: "以后阻止访问 %@", amendment.host)
            }
        case .decline:
            L10n.text("拒绝并继续任务", fallback: "拒绝并继续任务")
        case .cancel:
            L10n.text("拒绝并停止本轮", fallback: "拒绝并停止本轮")
        }
    }

    private func interactionMetadata(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jsonDisclosure(_ title: String, value: JSONValue) -> some View {
        DisclosureGroup(title) {
            jsonText(value)
                .padding(.top, 7)
        }
        .font(.caption.weight(.semibold))
    }

    private func jsonBlock(title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.semibold))
            jsonText(value)
        }
    }

    private func jsonText(_ value: JSONValue) -> some View {
        ScrollView(.horizontal) {
            Text(InteractionJSON.prettyString(value))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
        .padding(7)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { answers[questionID] ?? "" },
            set: { answers[questionID] = $0 }
        )
    }

    private func answersAreComplete(for input: CodexUserInputRequest) -> Bool {
        guard input.questions.count <= 3 else { return false }
        return input.questions.allSatisfy { question in
            guard let answer = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty
            else { return false }
            if question.isSecret { return true }
            if !question.isOther, let options = question.options, !options.isEmpty {
                return options.contains { $0.label == answer }
            }
            return true
        }
    }

    private func answerPayload(for input: CodexUserInputRequest) -> [String: [String]] {
        input.questions.reduce(into: [:]) { payload, question in
            guard let answer = answers[question.id],
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            payload[question.id] = [answer]
        }
    }

    private var parsedFormObject: JSONValue? {
        guard let value = InteractionJSON.parse(formJSON), value.objectValue != nil else { return nil }
        return value
    }

    private func submit(_ response: CodexInteractionResponse) {
        localError = nil
        respond(response)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openInBrowser(_ url: URL) {
        guard isSafeWebURL(url) else {
            localError = "仅允许打开 http 或 https 链接。"
            return
        }
        guard openURL(url) else {
            localError = "无法打开浏览器链接。"
            return
        }
        didOpenElicitationURL = true
        localError = nil
    }

    private func isSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return false }
        return true
    }
}

private enum InteractionJSON {
    static func prettyString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "无法格式化 JSON" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }
}
