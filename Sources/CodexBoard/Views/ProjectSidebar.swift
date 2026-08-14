import AppKit
import SwiftUI

struct ProjectSidebar: View {
    @Bindable var store: BoardStore
    @State private var searchText = ""
    @State private var projectPendingRemoval: ProjectRecord?

    private var filteredProjects: [ProjectRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.visibleProjects }
        return store.visibleProjects.filter {
            $0.name.localizedStandardContains(query)
                || $0.path.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            TextField("搜索项目", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            List(selection: $store.selectedProjectID) {
                Section("项目") {
                    ForEach(filteredProjects) { project in
                        projectRow(project)
                            .tag(project.id)
                            .contextMenu {
                                Button("在 Finder 中显示") { store.revealProject(project) }
                                    .disabled(!project.existsOnDisk)
                                Divider()
                                Button("从列表移除…", role: .destructive) {
                                    projectPendingRemoval = project
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filteredProjects.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView {
                            Label("没有可用项目", systemImage: "folder.badge.questionmark")
                        } description: {
                            Text("刷新 Codex 项目，或从下方添加一个项目文件夹。")
                        } actions: {
                            Button("刷新项目") {
                                Task { await store.refreshProjects() }
                            }
                            .disabled(store.isRefreshingProjects)
                        }
                    }
                }
            }

            Divider()
            Button {
                chooseProjectDirectory()
            } label: {
                Label("添加项目文件夹", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .confirmationDialog(
            "从项目列表移除？",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: projectPendingRemoval
        ) { project in
            Button("从列表移除", role: .destructive) {
                store.removeProjectFromSidebar(project)
                projectPendingRemoval = nil
            }
            Button("取消", role: .cancel) {
                projectPendingRemoval = nil
            }
        } message: { project in
            Text(removalConfirmationMessage(for: project))
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(BoardTheme.accent.gradient)
                    .frame(width: 30, height: 30)
                Image(systemName: "rectangle.3.group.fill")
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBoard")
                    .font(.headline)
                Text(L10n.localizedRuntimeText(store.statusMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isRefreshingProjects {
                ProgressView()
                    .controlSize(.small)
                    .help("正在刷新项目")
            } else {
                Button {
                    Task { await store.refreshProjects() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新项目")
                .accessibilityLabel("刷新项目")
            }
            Circle()
                .fill(store.accountReady ? BoardTheme.completed : BoardTheme.danger)
                .frame(width: 8, height: 8)
                .help(store.accountReady ? "本机 Codex 已连接" : "Codex 未连接")
        }
        .padding(12)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: project.isGitRepository ? "point.3.connected.trianglepath.dotted" : "folder")
                .foregroundStyle(project.existsOnDisk ? BoardTheme.accent : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .lineLimit(1)
                    if project.activeThreadCount > 0 {
                        Circle()
                            .fill(BoardTheme.executing)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(project.existsOnDisk
                     ? L10n.format(
                        "%lld 个会话 · %@",
                        fallback: "%lld 个会话 · %@",
                        Int64(project.threadCount),
                        BoardFormatters.relativeDate(project.latestActivityAt)
                     )
                     : L10n.text("目录已不存在", fallback: "目录已不存在"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(BoardFormatters.displayPath(project.path))
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("添加项目文件夹", fallback: "添加项目文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addManualProject(path: url.path)
    }

    private func removalConfirmationMessage(for project: ProjectRecord) -> String {
        let taskCount = store.tasks.count { $0.projectID == project.id }
        return L10n.format(
            "project.remove.confirmation",
            fallback: "只会将“%@”从 CodexBoard 左侧列表隐藏；其 %lld 个任务、Codex 会话和磁盘目录都不会删除。",
            project.name,
            Int64(taskCount)
        )
    }
}
