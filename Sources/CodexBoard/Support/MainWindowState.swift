import Observation

@MainActor
@Observable
final class MainWindowState {
    var isComposerPresented = false

    func requestComposer() {
        isComposerPresented = true
    }
}
