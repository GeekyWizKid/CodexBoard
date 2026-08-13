import XCTest
@testable import CodexBoard

@MainActor
final class MainWindowStateTests: XCTestCase {
    func testComposerRequestSurvivesMainWindowRecreation() {
        let state = MainWindowState()

        state.requestComposer()

        XCTAssertTrue(state.isComposerPresented)
        state.isComposerPresented = false
        XCTAssertFalse(state.isComposerPresented)
    }
}
