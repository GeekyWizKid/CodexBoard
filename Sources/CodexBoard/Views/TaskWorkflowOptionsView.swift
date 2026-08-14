import SwiftUI

struct TaskWorkflowOptionsView: View {
    let store: BoardStore
    let projectID: String
    @Binding var workspaceKind: TaskWorkspaceKind
    @Binding var dependencyIDs: Set<UUID>

    @State private var dependenciesExpanded = false

    private var project: ProjectRecord? {
        store.visibleProjects.first(where: { $0.id == projectID })
    }

    private var candidates: [BoardTask] {
        store.dependencyCandidates(for: projectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("执行工作区", selection: $workspaceKind) {
                ForEach(project?.isGitRepository == true ? TaskWorkspaceKind.allCases : [.project]) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Text(workspaceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

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
            dependencyIDs.removeAll()
            if project?.isGitRepository != true {
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

    private var workspaceDescription: String {
        if workspaceKind == .worktree {
            if project?.isGitRepository == true {
                return L10n.text(
                    "执行前自动创建 codex/task-* 分支和隔离目录；规划仍在原项目只读进行。",
                    fallback: "执行前自动创建 codex/task-* 分支和隔离目录；规划仍在原项目只读进行。"
                )
            }
            return L10n.text(
                "所选项目不是 Git 仓库，无法使用独立 Worktree。",
                fallback: "所选项目不是 Git 仓库，无法使用独立 Worktree。"
            )
        }
        return L10n.text(
            "直接在当前项目目录执行；主目录任务彼此串行，独立 Worktree 仍可并行。",
            fallback: "直接在当前项目目录执行；主目录任务彼此串行，独立 Worktree 仍可并行。"
        )
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
