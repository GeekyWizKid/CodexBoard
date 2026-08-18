import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: BoardStore
    @State private var newHostAlias = ""
    @State private var newHostName = ""
    @State private var hostMessage: String?
    @State private var hostRowMessages: [String: String] = [:]
    @State private var testingHostIDs: Set<String> = []
    @State private var showingRemoteSetupGuide = true

    var body: some View {
        TabView {
            Form {
                Toggle("新任务默认全自动", isOn: binding(\.defaultAutoRun))
                Stepper(
                    "所有主机最多同时执行 \(store.preferences.maxConcurrentExecutions) 个任务",
                    value: binding(\.maxConcurrentExecutions),
                    in: 1...32
                )
                Toggle("执行阶段允许网络访问", isOn: binding(\.allowNetworkAccess))
                Toggle("显示目录已丢失的历史项目", isOn: binding(\.showMissingProjects))
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                TextField("模型覆盖（留空使用本机默认）", text: binding(\.modelOverride))
                Picker("规划推理强度", selection: binding(\.planningEffort)) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                Picker("执行推理强度", selection: binding(\.executionEffort)) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                LabeledContent("规划权限", value: "只读，无网络")
                LabeledContent("执行权限", value: "仅项目目录可写")
            }
            .formStyle(.grouped)
            .tabItem { Label("Codex", systemImage: "sparkles") }

            hostsSettings
                .tabItem { Label("主机", systemImage: "server.rack") }
        }
        .frame(width: 660, height: 600)
    }

    private var hostsSettings: some View {
        Form {
            Section("添加 SSH 主机") {
                remoteSetupGuide

                TextField(
                    "SSH Host 别名",
                    text: $newHostAlias,
                    prompt: Text("例如 devbox（对应 ~/.ssh/config 中的 Host）")
                )
                TextField("显示名称（可选）", text: $newHostName)
                    .onSubmit(addHost)

                HStack {
                    if store.sshHostSuggestions.isEmpty {
                        Text("未在 ~/.ssh/config 中发现可用别名")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Menu("从 SSH 配置选择") {
                            ForEach(store.sshHostSuggestions, id: \.self) { alias in
                                Button(alias) {
                                    newHostAlias = alias
                                    if newHostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        newHostName = alias
                                    }
                                    hostMessage = nil
                                }
                            }
                        }
                    }

                    Spacer()
                    Button("添加主机", action: addHost)
                        .buttonStyle(.borderedProminent)
                        .disabled(newHostAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let hostMessage {
                    Text(hostMessage)
                        .font(.caption)
                        .foregroundStyle(BoardTheme.danger)
                }

                Label(
                    "测试连接要求 SSH 已可免交互登录，且远端非交互 SSH 会话能直接找到 codex。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("已配置主机") {
                ForEach(store.hosts) { host in
                    hostRow(host)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var remoteSetupGuide: some View {
        DisclosureGroup(isExpanded: $showingRemoteSetupGuide) {
            VStack(alignment: .leading, spacing: 16) {
                setupStep(
                    number: 1,
                    title: "在这台 Mac 配置 SSH 别名",
                    detail: "将具体主机写入 ~/.ssh/config。CodexBoard 使用 Host 后面的别名，不读取或保存 SSH 私钥。"
                ) {
                    CopyableCommandView(
                        command: "Host devbox\n  HostName devbox.example.com\n  User you\n  IdentityFile ~/.ssh/id_ed25519",
                        copyActionTitle: "复制 SSH 配置"
                    )
                }

                setupStep(
                    number: 2,
                    title: "登录远程机器并准备 Codex",
                    detail: "先在这台 Mac 登录远程机器；进入远端 shell 后，再执行第二段命令安装并授权 Codex。安装命令适用于 macOS 和 Linux。"
                ) {
                    CopyableCommandView(
                        command: interactiveSSHCommand,
                        copyActionTitle: "复制 SSH 登录命令"
                    )
                    CopyableCommandView(
                        command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh\ncodex login --device-auth\ncodex login status",
                        copyActionTitle: "复制远端准备命令"
                    )
                }

                setupStep(
                    number: 3,
                    title: "按 CodexBoard 的连接方式验证",
                    detail: "退出远端 shell，再在这台 Mac 执行下面的非交互检查。成功显示版本号后，把同一个别名填到下方。"
                ) {
                    CopyableCommandView(
                        command: remoteVerificationCommand,
                        copyActionTitle: "复制验证命令"
                    )
                }

                HStack(spacing: 14) {
                    Link(
                        "OpenAI SSH 连接说明",
                        destination: URL(string: "https://learn.chatgpt.com/docs/remote-connections")!
                    )
                    Link(
                        "Codex CLI 安装说明",
                        destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!
                    )
                }
                .font(.caption)
            }
            .padding(.top, 10)
            .padding(.leading, 2)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("第一次添加？按 3 步准备远程机器")
                        .font(.body.weight(.medium))
                    Text("准备完成后，CodexBoard 会通过系统 SSH 启动远端 Codex。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(BoardTheme.accent)
            }
        }
    }

    private var displaySSHHostAlias: String {
        let alias = newHostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? AppServerTransport.validateSSHHostAlias(alias)) != nil else {
            return "devbox"
        }
        return alias
    }

    private var interactiveSSHCommand: String {
        "ssh \(displaySSHHostAlias)"
    }

    private var remoteVerificationCommand: String {
        "ssh -T -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=15 -- \(displaySSHHostAlias) 'codex --version'"
    }

    private func setupStep<Content: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(BoardTheme.accent, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("第 \(number) 步，\(title)")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func hostRow(_ host: CodexHost) -> some View {
        let isTesting = testingHostIDs.contains(host.id)
        let state = store.hostConnectionState(for: host.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: store.isLocalHost(host.id) ? "desktopcomputer" : "server.rack")
                    .foregroundStyle(host.isEnabled ? state.hostStatusColor : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.hostName(for: host.id))
                        .font(.body.weight(.medium))
                    HStack(spacing: 5) {
                        if let alias = host.sshAlias {
                            Text(alias)
                            Text("·")
                        }
                        Text(host.isEnabled ? state.hostStatusDetail : "已停用")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(state.hostStatusDetail)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Stepper(
                    "并发 \(host.maxConcurrentExecutions)",
                    value: Binding(
                        get: { host.maxConcurrentExecutions },
                        set: { store.setHostConcurrency(id: host.id, maximum: $0) }
                    ),
                    in: 1...8
                )
                .controlSize(.small)
                .fixedSize()
                .help("此主机最多同时执行的任务数")
                .disabled(isTesting)

                Spacer()

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22)
                        .accessibilityLabel("正在测试 \(host.name)")
                } else {
                    Button {
                        testHost(host.id)
                    } label: {
                        Image(systemName: "wave.3.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!host.isEnabled)
                    .help("测试连接")
                    .accessibilityLabel("测试 \(host.name) 的连接")
                }

                Toggle(
                    "启用 \(host.name)",
                    isOn: Binding(
                        get: { store.enabledHosts.contains(where: { $0.id == host.id }) },
                        set: { enabled in
                            if store.setHostEnabled(id: host.id, enabled: enabled) {
                                hostRowMessages[host.id] = nil
                            } else {
                                hostRowMessages[host.id] = store.lastError
                                    ?? "主机状态暂时无法更改。"
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isTesting)
                .help(host.isEnabled ? "停用主机" : "启用主机")

                Button(role: .destructive) {
                    if !store.removeHost(id: host.id) {
                        hostRowMessages[host.id] = "无法删除：仍有项目或任务引用这台主机。"
                    } else {
                        hostRowMessages[host.id] = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.isLocalHost(host.id) || isTesting)
                .help(store.isLocalHost(host.id) ? "本机主机不能删除" : "删除主机")
                .accessibilityLabel("删除 \(host.name)")
            }

            if let message = hostRowMessages[host.id] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func addHost() {
        let alias = newHostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return }
        guard store.addSSHHost(alias: alias, name: name) else {
            hostMessage = store.lastError
                ?? "无法添加主机。请检查别名格式，或确认它尚未添加。"
            return
        }
        newHostAlias = ""
        newHostName = ""
        hostMessage = nil
    }

    private func testHost(_ hostID: String) {
        testingHostIDs.insert(hostID)
        Task {
            await store.testHost(id: hostID)
            if case let .failed(message) = store.hostConnectionState(for: hostID) {
                hostRowMessages[hostID] = message
            } else {
                hostRowMessages[hostID] = nil
            }
            testingHostIDs.remove(hostID)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BoardPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct CopyableCommandView: View {
    let command: String
    let copyActionTitle: String
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                didCopy = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(didCopy ? "已复制" : copyActionTitle)
            .accessibilityLabel(didCopy ? "已复制" : copyActionTitle)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension CodexConnectionState {
    var hostStatusTitle: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .failed: "连接失败"
        }
    }

    var hostStatusColor: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting: BoardTheme.approval
        case .connected: BoardTheme.completed
        case .failed: BoardTheme.danger
        }
    }

    var hostStatusDetail: String {
        if case let .failed(message) = self { return message }
        return hostStatusTitle
    }

}
