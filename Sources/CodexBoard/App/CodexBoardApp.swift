import AppKit
import SwiftUI

@main
struct CodexBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BoardStore()
    @State private var mainWindowState = MainWindowState()
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    var body: some Scene {
        Window("CodexBoard", id: "main") {
            ContentView(store: store, mainWindowState: mainWindowState)
                .frame(minWidth: 1_080, minHeight: 680)
                .environment(\.locale, appLanguage.locale)
                .task { store.start() }
        }
        .defaultSize(width: 1_440, height: 860)
        .commands {
            BoardCommands(store: store, mainWindowState: mainWindowState)
        }

        Settings {
            SettingsView(store: store)
                .environment(\.locale, appLanguage.locale)
        }

        MenuBarExtra {
            RunningTasksMenuView(store: store, mainWindowState: mainWindowState)
                .environment(\.locale, appLanguage.locale)
        } label: {
            TaskAttentionMenuBarLabel(
                store: store,
                notificationService: appDelegate.taskNotificationService
            )
            .environment(\.locale, appLanguage.locale)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct TaskAttentionMenuBarLabel: View {
    let store: BoardStore
    let notificationService: TaskNotificationService
    @Environment(\.openWindow) private var openWindow
    @State private var lastPresentedFocusNonce: UUID?

    var body: some View {
        Group {
            if store.runningTaskCount > 0 {
                Label(
                    store.runningTaskCount.formatted(),
                    systemImage: "bolt.circle.fill"
                )
                .accessibilityLabel(L10n.format(
                    "accessibility.tasks.running",
                    fallback: "CodexBoard, %lld tasks running",
                    Int64(store.runningTaskCount)
                ))
            } else {
                Image(systemName: "rectangle.3.group")
                    .accessibilityLabel(L10n.text(
                        "accessibility.tasks.idle",
                        fallback: "CodexBoard, no tasks running"
                    ))
            }
        }
        .onAppear {
            notificationService.setOpenTaskHandler { [weak store] taskID in
                _ = store?.focusAttentionTask(taskID)
            }
            notificationService.synchronize(with: store.attentionNotices)
            present(store.taskFocusRequest)
        }
        .onChange(of: store.attentionNotices) { _, notices in
            notificationService.synchronize(with: notices)
        }
        .onChange(of: store.taskFocusRequest) { _, request in
            present(request)
        }
    }

    private func present(_ request: TaskFocusRequest?) {
        guard let request,
              store.attentionNotices.contains(where: { $0.taskID == request.taskID }),
              lastPresentedFocusNonce != request.nonce
        else { return }
        lastPresentedFocusNonce = request.nonce
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BoardCommands: Commands {
    let store: BoardStore
    let mainWindowState: MainWindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu(L10n.text("menu.board", fallback: "Board")) {
            Button(L10n.text("action.new_task", fallback: "New Task")) {
                mainWindowState.requestComposer()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("n")

            Button(L10n.text("action.refresh_projects", fallback: "Refresh Projects")) {
                Task { await store.refreshProjects() }
            }
            .keyboardShortcut("r")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let taskNotificationService = TaskNotificationService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        taskNotificationService.refreshAuthorizationStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
