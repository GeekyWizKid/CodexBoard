import SwiftUI

struct TaskCapabilitiesPicker: View {
    let store: BoardStore
    let projectID: String
    @Binding var selectedSkillIDs: Set<String>
    @Binding var selectedAppIDs: Set<String>
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                catalogStatus

                capabilityGroup(
                    title: "Skills",
                    systemImage: "sparkles",
                    isEmpty: sortedSkills.isEmpty,
                    emptyMessage: "未发现可用的 Skill。"
                ) {
                    ForEach(sortedSkills) { skill in
                        Toggle(isOn: skillSelection(for: skill)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(skill.name)
                                    Text(skill.scope)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(skillDescription(skill))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if !skill.enabled {
                                    Text("当前 Skill 未启用，暂不可选择。")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!skill.enabled)
                    }
                }

                Divider()

                capabilityGroup(
                    title: "Apps",
                    systemImage: "square.grid.2x2",
                    isEmpty: sortedApps.isEmpty,
                    emptyMessage: "未发现可用的 App。"
                ) {
                    ForEach(sortedApps) { app in
                        Toggle(isOn: appSelection(for: app)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(app.name)
                                    if app.containsWriteTools {
                                        Text("当前不开放")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(BoardTheme.danger)
                                    } else {
                                        Text("只读")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !app.description.isEmpty {
                                    Text(app.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if let unavailableReason = appUnavailableReason(app) {
                                    Text(unavailableReason)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!isSelectable(app))
                    }
                }

                Text("当前仅开放全部已启用工具均为只读的 App。含写入工具的 App 会显示在目录中，但不能加入任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Label("任务能力（可选）", systemImage: "wand.and.stars")
                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: store.availableSkills) { _, _ in
            reconcileSelection()
        }
        .onChange(of: store.availableApps) { _, _ in
            reconcileSelection()
        }
    }

    @ViewBuilder
    private var catalogStatus: some View {
        if store.isLoadingCapabilities && store.availableSkills.isEmpty && store.availableApps.isEmpty {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("正在载入本机能力目录…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.capabilityCatalogError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BoardTheme.danger)
                    .lineLimit(2)
                HStack {
                    Text("能力目录失败不会阻止创建任务；可保持空选继续。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") {
                        Task { await store.refreshCapabilities(projectID: projectID, forceRefresh: true) }
                    }
                    .controlSize(.small)
                    .disabled(store.isLoadingCapabilities || projectID.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityGroup<Content: View>(
        title: String,
        systemImage: String,
        isEmpty: Bool,
        emptyMessage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
                .font(.callout.weight(.semibold))

            if isEmpty {
                Text(LocalizedStringKey(emptyMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    content()
                }
                .padding(.leading, 2)
            }
        }
    }

    private var sortedSkills: [CodexSkillMetadata] {
        store.availableSkills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var sortedApps: [CodexApp] {
        store.availableApps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var selectionSummary: String {
        let count = selectedSkillIDs.count + selectedAppIDs.count
        return count == 0
            ? L10n.text("默认不启用", fallback: "默认不启用")
            : L10n.format("已选 %lld 项", fallback: "已选 %lld 项", Int64(count))
    }

    private func skillDescription(_ skill: CodexSkillMetadata) -> String {
        let shortDescription = skill.shortDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let shortDescription, !shortDescription.isEmpty {
            return shortDescription
        }
        return skill.description
    }

    private func appUnavailableReason(_ app: CodexApp) -> String? {
        if isSelectable(app) {
            return nil
        }
        if !app.isAccessible {
            return L10n.text("当前账号无权访问此 App。", fallback: "当前账号无权访问此 App。")
        }
        if !app.isEnabled {
            return L10n.text("当前 App 未启用。", fallback: "当前 App 未启用。")
        }
        if !app.isCallable {
            return L10n.text("当前 App 未提供可调用工具。", fallback: "当前 App 未提供可调用工具。")
        }
        if app.enabledTools.isEmpty {
            return L10n.text("当前 App 没有已启用工具。", fallback: "当前 App 没有已启用工具。")
        }
        if app.containsWriteTools {
            return L10n.text(
                "含写入工具；为避免本机策略绕过人工审批，当前版本不开放。",
                fallback: "含写入工具；为避免本机策略绕过人工审批，当前版本不开放。"
            )
        }
        return L10n.text("当前 App 暂不可用于任务。", fallback: "当前 App 暂不可用于任务。")
    }

    private func isSelectable(_ app: CodexApp) -> Bool {
        app.supportsReadOnlyUse
    }

    private func skillSelection(for skill: CodexSkillMetadata) -> Binding<Bool> {
        Binding(
            get: { selectedSkillIDs.contains(skill.id) },
            set: { isSelected in
                guard skill.enabled || !isSelected else { return }
                if isSelected {
                    selectedSkillIDs.insert(skill.id)
                } else {
                    selectedSkillIDs.remove(skill.id)
                }
            }
        )
    }

    private func appSelection(for app: CodexApp) -> Binding<Bool> {
        Binding(
            get: { selectedAppIDs.contains(app.id) },
            set: { isSelected in
                guard isSelectable(app) || !isSelected else { return }
                if isSelected {
                    selectedAppIDs.insert(app.id)
                } else {
                    selectedAppIDs.remove(app.id)
                }
            }
        )
    }

    private func reconcileSelection() {
        let enabledSkillIDs = Set(store.availableSkills.lazy.filter(\.enabled).map(\.id))
        let selectableAppIDs = Set(store.availableApps.lazy.filter { isSelectable($0) }.map(\.id))
        selectedSkillIDs.formIntersection(enabledSkillIDs)
        selectedAppIDs.formIntersection(selectableAppIDs)
    }
}
