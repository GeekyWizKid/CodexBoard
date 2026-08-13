import AppKit
import SwiftUI

@MainActor
enum MainWindowBridge {
    static let identifier = NSUserInterfaceItemIdentifier("CodexBoard.mainWindow")

    @discardableResult
    static func revealExistingWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            return false
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MarkerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MainWindowBridge.identifier
        }
    }
}
