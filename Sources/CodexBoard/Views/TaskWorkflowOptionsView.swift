import SwiftUI

struct TaskWorkflowOptionsView: View {
    let store: BoardStore
    let projectID: String
    @Binding var workspaceKind: TaskWorkspaceKind
    @Binding var dependencyIDs: Set<UUID>

    @State private var dependenciesExpanded = false
    @State private var capabilityProbeRequestID: UUID?

    private var project: ProjectRecord? {
        store.visibleProjects.first(where: { $0.id == projectID })
    }

    private var candidates: [BoardTask] {
        store.dependencyCandidates(for: projectID)
    }

    private var isRemoteProject: Bool {
        project.map { !store.isLocalHost($0.hostID) } == true
    }

    private var worktreeAvailability: WorktreeCapabilityAvailability {
        store.worktreeCapabilityAvailability(for: projectID)
    }

    private var isWorktreeSupported: Bool {
        if case .supported(.managedV1) = worktreeAvailability { return true }
        return false
    }

    private var isWorktreeProbing: Bool {
        store.isProbingWorktreeCapability(for: projectID)
    }

    private var hasResolvedWorktreeCapability: Bool {
        store.hasResolvedWorktreeCapability(for: projectID)
    }

    private var availableWorkspaceKinds: [TaskWorkspaceKind] {
        let preservesPendingSelection = workspaceKind == .worktree
            && (!hasResolvedWorktreeCapability || isWorktreeProbing)
        return project?.isGitRepository == true && (isWorktreeSupported || preservesPendingSelection)
            ? TaskWorkspaceKind.allCases
            : [.project]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("执行工作区", selection: $workspaceKind) {
                ForEach(availableWorkspaceKinds) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            workspaceStatus

            DisclosureGroup(isExpanded: $dependenciesExpanded) {
                dependencyList
                    .padding(.top, 6)
            } label: {
                HStack {
                    Label("前置任务", systemImage: "point.3.connected.trianglepath.dotted")
                    Spacer()
                    if !dependencyIDs.isEmpty {
                        Text("已选 \(dependencyIDs.count) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: projectID) { _, _ in
            capabilityProbeRequestID = nil
            dependencyIDs.removeAll()
            if project?.isGitRepository != true || !isWorktreeSupported {
                workspaceKind = .project
            }
        }
        .onChange(of: worktreeAvailability) { _, availability in
            guard hasResolvedWorktreeCapability, !isWorktreeProbing else { return }
            if case .supported(.managedV1) = availability {
                return
            }
            workspaceKind = .project
        }
        .task(id: projectID) {
            let requestID = UUID()
            capabilityProbeRequestID = requestID
            defer {
                if capabilityProbeRequestID == requestID {
                    capabilityProbeRequestID = nil
                }
            }
            let availability = await store.refreshWorktreeCapability(projectID: projectID)
            guard !Task.isCancelled,
                  capabilityProbeRequestID == requestID,
                  let availability
            else { return }
            if case .supported(.managedV1) = availability {
                return
            } else {
                workspaceKind = .project
            }
        }
    }

    @ViewBuilder
    private var dependencyList: some View {
        if candidates.isEmpty {
            Text("该项目还没有可作为前置条件的任务。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(candidates) { task in
                        Toggle(isOn: dependencyBinding(task.id)) {
                            HStack(spacing: 7) {
                                Image(systemName: task.stage.symbol)
                                    .foregroundStyle(BoardTheme.color(for: task.stage))
                                    .frame(width: 16)
                                Text(task.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(task.stage.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 105)
        }
    }

    @ViewBuilder
    private var workspaceStatus: some View {
        if isWorktreeProbing {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(workspaceDescription)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("执行工作区状态")
            .accessibilityValue(workspaceDescription)
        } else {
            Label(workspaceDescription, systemImage: workspaceStatusSystemImage)
                .font(.caption)
                .foregroundStyle(workspaceStatusColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("执行工作区状态")
                .accessibilityValue(workspaceDescription)
        }
    }

    private var workspaceDescription: String {
        if isWorktreeProbing {
            return isRemoteProject
                ? "正在向对应远程主机确认完整 Worktree 能力…"
                : "正在验证本机 Git HEAD 与 Worktree 能力…"
        }
        if workspaceKind == .worktree, project?.isGitRepository == true, isWorktreeSupported {
            return L10n.text(
                "执行前会在独立任务分支创建真实的基线提交，包含已跟踪文件的暂存与未暂存改动，以及非忽略的未跟踪文件；Git ignored 文件不纳入，源目录和索引保持不变。规划仍在原项目只读进行。",
                fallback: "执行前会在独立任务分支创建真实的基线提交，包含已跟踪文件的暂存与未暂存改动，以及非忽略的未跟踪文件；Git ignored 文件不纳入，源目录和索引保持不变。规划仍在原项目只读进行。"
            )
        }
        switch worktreeAvailability {
        case .supported:
            break
        case let .unsupported(reason):
            return isRemoteProject
                ? "该远程主机当前不支持由 CodexBoard 管理的独立 Worktree：\(reason) 当前选择将直接在服务器项目目录执行。"
                : "该项目当前不支持独立 Worktree：\(reason) 当前选择将直接在项目目录执行。"
        case let .unavailable(reason):
            return isRemoteProject
                ? "暂时无法确认该远程主机的完整 Worktree 能力：\(reason) 当前选择将直接在服务器项目目录执行。"
                : "暂时无法确认该项目的 Worktree 能力：\(reason) 当前选择将直接在项目目录执行。"
        }
        return L10n.text(
            "直接在当前项目目录执行；主目录任务彼此串行，独立 Worktree 仍可并行。",
            fallback: "直接在当前项目目录执行；主目录任务彼此串行，独立 Worktree 仍可并行。"
        )
    }

    private var workspaceStatusSystemImage: String {
        switch worktreeAvailability {
        case .supported:
            workspaceKind == .worktree ? "point.3.connected.trianglepath.dotted" : "folder"
        case .unsupported:
            "nosign"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var workspaceStatusColor: Color {
        switch worktreeAvailability {
        case .supported:
            .secondary
        case .unsupported:
            BoardTheme.danger
        case .unavailable:
            BoardTheme.approval
        }
    }

    private func dependencyBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { dependencyIDs.contains(id) },
            set: { selected in
                if selected {
                    dependencyIDs.insert(id)
                } else {
                    dependencyIDs.remove(id)
                }
            }
        )
    }
}
