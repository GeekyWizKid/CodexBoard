import AppKit
import SwiftUI

@main
struct CodexBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BoardStore()
    @State private var mainWindowState = MainWindowState()

    var body: some Scene {
        Window("CodexBoard", id: "main") {
            ContentView(store: store, mainWindowState: mainWindowState)
                .frame(minWidth: 1_080, minHeight: 680)
                .task { store.start() }
        }
        .defaultSize(width: 1_440, height: 860)
        .commands {
            BoardCommands(store: store, mainWindowState: mainWindowState)
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra {
            RunningTasksMenuView(store: store, mainWindowState: mainWindowState)
        } label: {
            if store.runningTaskCount > 0 {
                Label(
                    store.runningTaskCount.formatted(),
                    systemImage: "bolt.circle.fill"
                )
                .accessibilityLabel("CodexBoard，\(store.runningTaskCount) 个任务进行中")
            } else {
                Image(systemName: "rectangle.3.group")
                    .accessibilityLabel("CodexBoard，没有进行中的任务")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct BoardCommands: Commands {
    let store: BoardStore
    let mainWindowState: MainWindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("看板") {
            Button("新建任务") {
                mainWindowState.requestComposer()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("n")

            Button("刷新项目") {
                Task { await store.refreshProjects() }
            }
            .keyboardShortcut("r")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
