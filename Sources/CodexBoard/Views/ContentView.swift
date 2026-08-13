import SwiftUI

struct ContentView: View {
    let store: BoardStore
    @Bindable var mainWindowState: MainWindowState
    @State private var showingInspector = true

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            BoardView(store: store, showingComposer: $mainWindowState.isComposerPresented)
                .inspector(isPresented: $showingInspector) {
                    TaskInspector(store: store)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            mainWindowState.requestComposer()
                        } label: {
                            Label("新建任务", systemImage: "plus")
                        }

                        Button {
                            Task { await store.refreshProjects() }
                        } label: {
                            Label("刷新项目", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshingProjects)

                        Button {
                            showingInspector.toggle()
                        } label: {
                            Label("任务详情", systemImage: "sidebar.right")
                        }
                    }
                }
        }
        .navigationTitle(store.selectedProject?.name ?? "CodexBoard")
        .sheet(isPresented: $mainWindowState.isComposerPresented) {
            TaskComposer(store: store, isPresented: $mainWindowState.isComposerPresented)
        }
    }
}
