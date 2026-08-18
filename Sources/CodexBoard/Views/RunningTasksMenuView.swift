import AppKit
import SwiftUI

struct RunningTasksMenuView: View {
    @ObservedObject var store: BoardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.runningTasks.isEmpty {
                ContentUnavailableView(
                    "暂无进行中的任务",
                    systemImage: "checkmark.circle",
                    description: Text("开始规划或执行后，任务会显示在这里。")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.runningTasks) { task in
                            RunningTaskRow(
                                task: task,
                                projectName: store.projectName(for: task),
                                hostName: store.hostName(for: task.hostID),
                                openTask: { showBoard(taskID: task.id) },
                                stopTask: {
                                    Task { await store.cancel(taskID: task.id) }
                                }
                            )
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 380)
            }

            Divider()
            footer
        }
        .frame(width: 370)
        .task { store.start() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: store.runningTasks.isEmpty
                  ? "rectangle.3.group"
                  : "bolt.circle.fill")
                .font(.title3)
                .foregroundStyle(store.runningTasks.isEmpty ? Color.secondary : BoardTheme.executing)
            VStack(alignment: .leading, spacing: 1) {
                Text("CodexBoard")
                    .font(.headline)
                Text(store.runningTasks.isEmpty
                     ? "\(store.connectedHostCount)/\(store.enabledHosts.count) 台主机已连接"
                     : "\(store.runningTaskCount) 个任务进行中 · \(store.connectedHostCount) 台主机已连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(overallConnectionColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("\(store.connectedHostCount) 台主机已连接")
                .help(store.statusMessage)
        }
        .padding(12)
    }

    private var overallConnectionColor: Color {
        guard !store.enabledHosts.isEmpty else { return BoardTheme.danger }
        if store.connectedHostCount == store.enabledHosts.count { return BoardTheme.completed }
        if store.connectedHostCount > 0 { return BoardTheme.approval }
        return BoardTheme.danger
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showBoard()
            } label: {
                Label("打开看板", systemImage: "macwindow")
            }

            Button {
                showBoard(createTask: true)
            } label: {
                Label("新建任务", systemImage: "plus")
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("退出 CodexBoard")
            .help("退出 CodexBoard")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private func showBoard(taskID: UUID? = nil, createTask: Bool = false) {
        if let taskID { store.focusTask(taskID) }

        if MainWindowBridge.revealExistingWindow() {
            if createTask {
                NotificationCenter.default.post(name: .codexBoardNewTask, object: nil)
            }
            return
        }

        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            _ = MainWindowBridge.revealExistingWindow()
            if createTask {
                NotificationCenter.default.post(name: .codexBoardNewTask, object: nil)
            }
        }
    }
}

private struct RunningTaskRow: View {
    let task: BoardTask
    let projectName: String
    let hostName: String
    let openTask: () -> Void
    let stopTask: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openTask) {
                HStack(spacing: 10) {
                    Image(systemName: task.stage.symbol)
                        .foregroundStyle(BoardTheme.color(for: task.stage))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        Text("\(projectName) · \(hostName) · \(task.stage.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !task.liveMessage.isEmpty {
                            Text(task.liveMessage)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(BoardTheme.color(for: task.stage))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(shortTitle)，\(projectName)，\(hostName)，\(task.stage.title)")
            .help("在看板中查看")

            Button(role: .destructive, action: stopTask) {
                Image(systemName: "stop.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("停止任务")
            .accessibilityLabel("停止 \(shortTitle)")
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var shortTitle: String {
        task.title.count <= 30 ? task.title : "\(task.title.prefix(27))…"
    }
}
