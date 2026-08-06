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
    // 灰点 disconnected 非闪烁（与 error/attention 红橙闪严格区分）。
    func test_disconnectedCaseNotBlinking() {
        XCTAssertFalse(TabIndicator.disconnected.isBlinking)
    }
    // 红灰正交：resolve 仅在 connected 时判 systemError；未连接不产生红点。
    func test_notConnected_resolveStillNone_grayIsLayeredAbove() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: false, statuses: [.systemError]), .none)
    }
    func test_connectedSystemError_red() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: [.systemError]), .error)
    }
    func test_reduceMotionDisablesBlinking() {
        XCTAssertTrue(TabIndicator.error.shouldAnimate(reduceMotion: false))
        XCTAssertFalse(TabIndicator.error.shouldAnimate(reduceMotion: true))
        XCTAssertFalse(TabIndicator.running.shouldAnimate(reduceMotion: false))
    }
    func test_statusesHaveDistinctNonColorSymbols() {
        let symbols = [TabIndicator.unread, .running, .attention, .error, .disconnected]
            .compactMap(\.symbolName)
        XCTAssertEqual(Set(symbols).count, 5)
    }
}
