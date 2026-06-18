import XCTest
@testable import CodexRemote

final class ThreadBadgeTests: XCTestCase {

    // MARK: - LiveStatus.from(threadStatus:) 映射（设计 D1，B10）

    func test_liveStatus_idle_maps_none() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "idle", activeFlags: []), .none)
    }

    func test_liveStatus_notLoaded_maps_none() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "notLoaded", activeFlags: []), .none)
    }

    func test_liveStatus_active_no_flags_maps_running() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "active", activeFlags: []), .running)
    }

    func test_liveStatus_waitingOnUserInput_maps_waiting() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "active", activeFlags: ["waitingOnUserInput"]), .waiting)
    }

    func test_liveStatus_waitingOnApproval_maps_waiting() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "active", activeFlags: ["waitingOnApproval"]), .waiting)
    }

    // B10：两 flag 都在也只映射单一 waiting，避免双重徽标
    func test_liveStatus_both_waiting_flags_maps_single_waiting() {
        XCTAssertEqual(
            LiveStatus.from(threadStatus: "active",
                            activeFlags: ["waitingOnUserInput", "waitingOnApproval"]),
            .waiting)
    }

    func test_liveStatus_unknown_string_maps_none() {
        XCTAssertEqual(LiveStatus.from(threadStatus: "garbage", activeFlags: []), .none)
    }

    // MARK: - resolve 优先级仲裁（设计 D2：运行中 > 待处理 > 未读失败 > 未读完成 > 无）

    // B1：运行中压过未读完成
    func test_resolve_running_beats_unread_completed() {
        let b = ThreadBadge.resolve(live: .running, outcome: .completed, updatedAt: 100, viewedAt: 0)
        XCTAssertEqual(b, .running)
    }

    func test_resolve_waiting_beats_unread_failed() {
        let b = ThreadBadge.resolve(live: .waiting, outcome: .failed, updatedAt: 100, viewedAt: 0)
        XCTAssertEqual(b, .waiting)
    }

    func test_resolve_unread_failed_beats_unread_completed() {
        // live=none，outcome=failed 且未读 → 红
        let b = ThreadBadge.resolve(live: .none, outcome: .failed, updatedAt: 100, viewedAt: 0)
        XCTAssertEqual(b, .unreadFailed)
    }

    func test_resolve_unread_completed_when_only_completed() {
        let b = ThreadBadge.resolve(live: .none, outcome: .completed, updatedAt: 100, viewedAt: 0)
        XCTAssertEqual(b, .unreadCompleted)
    }

    func test_resolve_idle_no_outcome_is_none() {
        let b = ThreadBadge.resolve(live: .none, outcome: nil, updatedAt: 100, viewedAt: 0)
        XCTAssertEqual(b, .none)
    }

    // B9：updatedAt 严格大于 viewedAt 才算未读；相等 = 已读不亮
    func test_resolve_equal_updatedAt_viewedAt_not_unread() {
        let b = ThreadBadge.resolve(live: .none, outcome: .failed, updatedAt: 100, viewedAt: 100)
        XCTAssertEqual(b, .none)
    }

    func test_resolve_viewedAt_greater_not_unread() {
        let b = ThreadBadge.resolve(live: .none, outcome: .completed, updatedAt: 100, viewedAt: 200)
        XCTAssertEqual(b, .none)
    }

    // 已查看后实时态仍能显示（实时态不受 viewedAt gate）
    func test_resolve_running_shows_even_when_viewed() {
        let b = ThreadBadge.resolve(live: .running, outcome: .completed, updatedAt: 50, viewedAt: 100)
        XCTAssertEqual(b, .running)
    }
}
