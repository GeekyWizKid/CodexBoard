import AppKit
import SwiftUI

@main
struct CodexBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup("CodexBoard", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1_080, minHeight: 680)
                .task { store.start() }
        }
        .defaultSize(width: 1_440, height: 860)
        .commands {
            CommandMenu("看板") {
                Button("新建任务") {
                    NotificationCenter.default.post(name: .codexBoardNewTask, object: nil)
                }
                .keyboardShortcut("n")

                Button("刷新项目") {
                    Task { await store.refreshProjects() }
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let codexBoardNewTask = Notification.Name("CodexBoard.newTask")
}
