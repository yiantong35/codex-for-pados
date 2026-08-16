import XCTest
@testable import CodexRemote

@MainActor
final class WorkspaceLayoutStoreTests: XCTestCase {
    func test_toggleRight_focusesHiddenRequestedPanelBeforeClosingIt() {
        let s = WorkspaceLayoutStore(showRight: true)
        s.lastRequested = .left

        s.toggleRightPanel()
        XCTAssertTrue(s.showRight)
        XCTAssertEqual(s.lastRequested, .right)

        s.toggleRightPanel()
        XCTAssertFalse(s.showRight)
    }

    func test_toggleLeft_focusesHiddenRequestedPanelBeforeClosingIt() {
        let s = WorkspaceLayoutStore(leftVisible: true, showRight: true)
        s.lastRequested = .right

        s.toggleLeftPanel()
        XCTAssertTrue(s.leftVisible)
        XCTAssertEqual(s.lastRequested, .left)

        s.toggleLeftPanel()
        XCTAssertFalse(s.leftVisible)
    }
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

    func test_requestRightPanel_whenAlreadyOpen_staysOpenAndSetsIntent() {
        let s = WorkspaceLayoutStore(showRight: true)
        s.requestRightPanel(.review)
        XCTAssertTrue(s.showRight)
        XCTAssertEqual(s.pendingRightPanelIntent, .review)
    }

    func test_requestRightPanel_intentOverwrite_latestWins() {
        let s = WorkspaceLayoutStore()
        s.requestRightPanel(.files)
        s.requestRightPanel(.review)
        XCTAssertEqual(s.pendingRightPanelIntent, .review)   // one-shot latest-wins
    }

    func test_requestRightPanel_fullscreen_stillOpensRight() {
        let s = WorkspaceLayoutStore()
        s.requestRightPanel(.toggleFullscreen)
        XCTAssertTrue(s.showRight)
        XCTAssertEqual(s.pendingRightPanelIntent, .toggleFullscreen)
    }

    func test_pendingIntent_resetsToNilAfterConsume() {
        let s = WorkspaceLayoutStore()
        s.requestRightPanel(.files)
        XCTAssertNotNil(s.pendingRightPanelIntent)
        // 模拟 RightPanelContainerView 消费即复位（设计 D6）。
        s.pendingRightPanelIntent = nil
        XCTAssertNil(s.pendingRightPanelIntent)
    }
}
