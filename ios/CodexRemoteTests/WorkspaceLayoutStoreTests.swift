import XCTest
@testable import CodexRemote

@MainActor
final class WorkspaceLayoutStoreTests: XCTestCase {
    func test_defaultValues() {
        let s = WorkspaceLayoutStore()
        XCTAssertTrue(s.leftVisible)
        XCTAssertFalse(s.showRight)
        XCTAssertFalse(s.showBottom)
        XCTAssertFalse(s.showSummary)
        XCTAssertFalse(s.showSettings)
        XCTAssertNil(s.pendingRightPanelIntent)
    }

    func test_initialInjection_forSnapshots() {
        let s = WorkspaceLayoutStore(showRight: true, showBottom: true)
        XCTAssertTrue(s.showRight)
        XCTAssertTrue(s.showBottom)
    }

    func test_toggle() {
        let s = WorkspaceLayoutStore()
        s.showBottom.toggle()
        XCTAssertTrue(s.showBottom)
    }

    func test_requestRightPanel_opensRightAndSetsIntent() {
        let s = WorkspaceLayoutStore()
        s.requestRightPanel(.files)
        XCTAssertTrue(s.showRight, "跳转意图应先打开右栏")
        XCTAssertEqual(s.pendingRightPanelIntent, .files)
    }

    func test_intentTargetTabMapping() {
        XCTAssertEqual(RightPanelIntent.review.targetTab, .review)
        XCTAssertEqual(RightPanelIntent.files.targetTab, .files)
        XCTAssertEqual(RightPanelIntent.sideChat.targetTab, .sideChat)
        XCTAssertNil(RightPanelIntent.toggleFullscreen.targetTab)
    }
}
