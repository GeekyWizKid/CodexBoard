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
                     ? "所有任务均处于空闲状态"
                     : "\(store.runningTaskCount) 个任务进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(store.accountReady ? BoardTheme.completed : BoardTheme.danger)
                .frame(width: 8, height: 8)
                .accessibilityLabel(store.accountReady ? "本机 Codex 已连接" : "本机 Codex 未连接")
                .help(store.accountReady ? "本机 Codex 已连接" : "Codex 未连接")
        }
        .padding(12)
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

                        HStack(spacing: 5) {
                            Text(projectName)
                                .lineLimit(1)
                            Text("·")
                            Text(task.stage.title)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
            .accessibilityLabel("\(shortTitle)，\(projectName)，\(task.stage.title)")
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
