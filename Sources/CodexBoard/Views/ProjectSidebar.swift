import AppKit
import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: BoardStore
    @State private var searchText = ""
    @State private var remoteProjectHostID: String?
    @State private var remoteProjectPath = ""
    @State private var showingRemoteProjectSheet = false

    private var filteredProjects: [ProjectRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.visibleProjects }
        return store.visibleProjects.filter {
            $0.name.localizedStandardContains(query)
                || $0.path.localizedStandardContains(query)
                || store.hostName(for: $0.hostID).localizedStandardContains(query)
        }
    }

    private var enabledRemoteHosts: [CodexHost] {
        store.enabledHosts.filter { !store.isLocalHost($0.id) }
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
                                if store.isLocalHost(project.hostID) {
                                    Button("在 Finder 中显示") { store.revealProject(project) }
                                        .disabled(!project.existsOnDisk)
                                }
                                if project.isManual {
                                    Button("从手动项目中移除", role: .destructive) {
                                        store.removeManualProject(project)
                                    }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filteredProjects.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    chooseLocalProjectDirectory()
                } label: {
                    Label("添加本机项目…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if !enabledRemoteHosts.isEmpty {
                    Menu {
                        Section("添加远程项目") {
                            ForEach(enabledRemoteHosts) { host in
                                Button(store.hostName(for: host.id)) {
                                    remoteProjectHostID = host.id
                                    remoteProjectPath = ""
                                    showingRemoteProjectSheet = true
                                }
                            }
                        }
                    } label: {
                        Label("添加远程项目…", systemImage: "server.rack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .help("从远程主机添加项目路径")
                    .accessibilityLabel("添加远程项目")
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showingRemoteProjectSheet) {
            remoteProjectSheet
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
                Text("\(store.connectedHostCount)/\(store.enabledHosts.count) 台主机已连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(overallConnectionColor)
                .frame(width: 8, height: 8)
                .help(store.statusMessage)
                .accessibilityLabel("\(store.connectedHostCount) 台主机已连接")
        }
        .padding(12)
    }

    private var overallConnectionColor: Color {
        guard !store.enabledHosts.isEmpty else { return BoardTheme.danger }
        if store.connectedHostCount == store.enabledHosts.count { return BoardTheme.completed }
        if store.connectedHostCount > 0 { return BoardTheme.approval }
        return BoardTheme.danger
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
                Text(projectDetail(project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("\(store.hostName(for: project.hostID)) · \(project.path)")
    }

    private func projectDetail(_ project: ProjectRecord) -> String {
        let hostName = store.hostName(for: project.hostID)
        if store.host(for: project.hostID)?.isEnabled != true {
            return "\(hostName) · 已停用"
        }
        let state = store.hostConnectionState(for: project.hostID).hostStatusTitle
        guard project.existsOnDisk else { return "\(hostName) · \(state) · 路径未验证或不可用" }
        return "\(hostName) · \(state) · \(project.threadCount) 个会话"
    }

    private func chooseLocalProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "添加项目文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addManualProject(path: url.path, hostID: CodexHost.localID)
    }

    private var remoteProjectSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加远程项目")
                    .font(.title2.weight(.semibold))
                Text("主机：\(remoteProjectHostID.map(store.hostName(for:)) ?? "未知主机")")
                    .foregroundStyle(.secondary)
            }

            TextField("远程绝对路径，例如 /srv/project", text: $remoteProjectPath)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addRemoteProject)

            Text(remotePathHelp)
                .font(.caption)
                .foregroundStyle(isRemotePathValid || remoteProjectPath.isEmpty
                                 ? Color.secondary
                                 : BoardTheme.danger)

            HStack {
                Spacer()
                Button("取消") {
                    showingRemoteProjectSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("添加") {
                    addRemoteProject()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isRemotePathValid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func addRemoteProject() {
        guard let hostID = remoteProjectHostID else { return }
        let path = remoteProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRemotePathValid else { return }
        store.addManualProject(path: path, hostID: hostID)
        showingRemoteProjectSheet = false
    }

    private var isRemotePathValid: Bool {
        let path = remoteProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && (path as NSString).standardizingPath != "/"
    }

    private var remotePathHelp: String {
        if !remoteProjectPath.isEmpty, !isRemotePathValid {
            return "请输入以 / 开头的远程绝对路径；不能把根目录 / 作为项目。"
        }
        return "路径会原样交给远程 Codex，不会在本机 Finder 中打开。"
    }
}
