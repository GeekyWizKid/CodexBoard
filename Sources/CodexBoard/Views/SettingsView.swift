import SwiftUI

struct SettingsView: View {
    let store: BoardStore
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            Form {
                Picker("语言", selection: $appLanguageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                Toggle("新任务默认全自动", isOn: binding(\.defaultAutoRun))
                Stepper(
                    "最多同时执行 \(store.preferences.maxConcurrentExecutions) 个任务",
                    value: binding(\.maxConcurrentExecutions),
                    in: 1...4
                )
                Stepper(
                    "启动失败最多自动重试 \(store.preferences.maxAutomaticRetries) 次",
                    value: binding(\.maxAutomaticRetries),
                    in: 0...5
                )
                Text("只重试进入写入 turn 之前的临时启动错误；认证、限流、工作区和执行期失败会直接熔断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("执行阶段允许网络访问", isOn: binding(\.allowNetworkAccess))
                Toggle("显示目录已丢失的历史项目", isOn: binding(\.showMissingProjects))
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                TextField("新任务默认模型（留空使用本机默认）", text: binding(\.modelOverride))
                Picker("新任务默认推理强度", selection: binding(\.planningEffort)) {
                    ForEach(ReasoningEffort.standardCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                LabeledContent("规划权限", value: "只读，无网络")
                LabeledContent("执行权限", value: "仅项目目录可写")
            }
            .formStyle(.grouped)
            .tabItem { Label("Codex", systemImage: "sparkles") }

            connectionSettings
                .tabItem { Label("连接", systemImage: "link") }
        }
        .frame(width: 560, height: 410)
    }

    private var connectionSettings: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MCP 服务器")
                            .font(.headline)
                        Text("管理外部工具服务及其 OAuth 登录状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isLoadingMCPServers {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("刷新") {
                        Task { await store.refreshMCPServers() }
                    }
                    .disabled(store.isLoadingMCPServers)
                }

                if let error = store.mcpServerError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(BoardTheme.danger)
                        .textSelection(.enabled)
                }
            }

            Section("已配置的服务器") {
                if store.mcpServers.isEmpty, !store.isLoadingMCPServers {
                    Text("未发现 MCP 服务器。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.mcpServers) { server in
                        mcpServerRow(server)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await store.refreshMCPServers()
        }
    }

    private func mcpServerRow(_ server: CodexMCPServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(serverDisplayName(server))
                        .font(.callout.weight(.semibold))
                    if serverDisplayName(server) != server.name {
                        Text(server.name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(authStatusTitle(server.authStatus))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let description = cleaned(server.description) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Label("\(server.toolNames.count) 个工具", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let version = cleaned(server.version) {
                    Text("v\(version)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                if store.oauthServersInProgress.contains(server.name) {
                    ProgressView()
                        .controlSize(.small)
                    Text("等待浏览器授权…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if server.authStatus == "notLoggedIn" {
                    Button("登录") {
                        Task { await store.beginMCPOAuth(serverName: server.name) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func serverDisplayName(_ server: CodexMCPServerStatus) -> String {
        cleaned(server.title) ?? server.name
    }

    private func authStatusTitle(_ status: String) -> String {
        switch status {
        case "oAuth": L10n.text("OAuth 已登录", fallback: "OAuth 已登录")
        case "bearerToken": L10n.text("令牌已配置", fallback: "令牌已配置")
        case "notLoggedIn": L10n.text("未登录", fallback: "未登录")
        case "unsupported": L10n.text("无需 OAuth", fallback: "无需 OAuth")
        case "unknown": L10n.text("状态未知", fallback: "状态未知")
        default: status.isEmpty ? L10n.text("状态未知", fallback: "状态未知") : status
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BoardPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
