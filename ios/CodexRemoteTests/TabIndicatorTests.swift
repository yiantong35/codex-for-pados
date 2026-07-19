import XCTest
@testable import CodexRemote

final class TabIndicatorTests: XCTestCase {
    func test_disconnectedHasNoDot() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: false, statuses: [.active(activeFlags: [])]), .none)
    }
    func test_errorBeatsAll() {
        let s: [ThreadStatus] = [.active(activeFlags: []), .systemError]
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: s), .error)
    }
    func test_approvalBeatsRunning() {
        let s: [ThreadStatus] = [.active(activeFlags: []), .active(activeFlags: [.waitingOnApproval])]
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: s), .attention)
    }
    func test_waitingInputIsAttention() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true,
                        statuses: [.active(activeFlags: [.waitingOnUserInput])]), .attention)
    }
    func test_runningBeatsUnread() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true,
                        statuses: [.active(activeFlags: [])], hasUnread: true), .running)
    }
    func test_unreadOnly() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: [.idle], hasUnread: true), .unread)
    }
    func test_idleNoUnreadNone() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: [.idle], hasUnread: false), .none)
    }
    func test_emptyStatusesNoUnreadNone() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: [], hasUnread: false), .none)
    }
    func test_isBlinking() {
        XCTAssertTrue(TabIndicator.error.isBlinking)
        XCTAssertTrue(TabIndicator.attention.isBlinking)
        XCTAssertFalse(TabIndicator.running.isBlinking)
        XCTAssertFalse(TabIndicator.unread.isBlinking)
        XCTAssertFalse(TabIndicator.none.isBlinking)
    }
}
