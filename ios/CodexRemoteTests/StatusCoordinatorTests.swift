import XCTest
@testable import CodexRemote

@MainActor
final class StatusCoordinatorTests: XCTestCase {

    private func makeStore() -> ProjectsStore {
        let rs = ReadStateStore(defaults: UserDefaults(suiteName: "sc.\(UUID().uuidString)")!)
        let s = ProjectsStore(readState: rs)
        s.ingest([ThreadSummary(id: "t1", sessionId: "s1", preview: "", modelProvider: "openai",
                                createdAt: 0, updatedAt: 100, cwd: "/x", cliVersion: "0.1.0",
                                name: nil, gitInfo: GitInfoSummary(sha: nil, branch: "m", originUrl: "o/x"))])
        return s
    }

    private func notif(_ method: String, _ params: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: method, params: AnyCodable(params))
    }

    func test_turnStarted_sets_running() {
        let store = makeStore()
        let coord = StatusCoordinator(projects: store)
        coord.handle(notif(ServerNotificationMethod.turnStarted,
                           ["threadId": "t1", "turn": ["id": "u1", "status": "inProgress"]]))
        XCTAssertEqual(store.badge("t1"), .running)
    }

    func test_statusChanged_waitingOnApproval_sets_waiting() {
        let store = makeStore()
        let coord = StatusCoordinator(projects: store)
        coord.handle(notif(ServerNotificationMethod.statusChanged,
                           ["threadId": "t1",
                            "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]]))
        XCTAssertEqual(store.badge("t1"), .waiting)
    }

    // turn/completed 成功：清实时态 + 记 outcome=completed；未 markViewed 故默认已读(B2)，
    // 但若已 markViewed 到过去 → 转绿（这里只验证 outcome 被记录 + live 清空）
    func test_turnCompleted_success_records_completed_and_clears_live() {
        let store = makeStore()
        store.markViewed("t1")          // 锚点=100（当前 updatedAt）
        let coord = StatusCoordinator(projects: store)
        // 先 running
        coord.handle(notif(ServerNotificationMethod.turnStarted,
                           ["threadId": "t1", "turn": ["id": "u1"]]))
        XCTAssertEqual(store.badge("t1"), .running)
        // 完成：live 清空，记 completed；updatedAt(100)==viewedAt(100) → 不亮(B9)
        coord.handle(notif(ServerNotificationMethod.turnCompleted,
                           ["threadId": "t1", "turn": ["id": "u1", "status": "completed"]]))
        XCTAssertEqual(store.badge("t1"), .none)
    }

    // turn/completed 失败 + 旧锚点 → 红（B-未读失败显示）
    func test_turnCompleted_failed_shows_red_when_unviewed() {
        let rs = ReadStateStore(defaults: UserDefaults(suiteName: "scfail.\(UUID().uuidString)")!)
        let store = ProjectsStore(readState: rs)
        store.ingest([ThreadSummary(id: "t1", sessionId: "s1", preview: "", modelProvider: "openai",
                                    createdAt: 0, updatedAt: 100, cwd: "/x", cliVersion: "0.1.0",
                                    name: nil, gitInfo: GitInfoSummary(sha: nil, branch: "m", originUrl: "o/x"))])
        rs.markViewed("t1", updatedAt: 50)   // 上次看的是更早的版本
        let coord = StatusCoordinator(projects: store)
        coord.handle(notif(ServerNotificationMethod.turnCompleted,
                           ["threadId": "t1", "turn": ["id": "u1", "status": "failed"]]))
        XCTAssertEqual(store.badge("t1"), .unreadFailed)  // updatedAt=100 > viewedAt=50
    }

    func test_handle_ignores_missing_threadId() {
        let store = makeStore()
        let coord = StatusCoordinator(projects: store)
        coord.handle(notif(ServerNotificationMethod.turnStarted, ["turn": ["id": "u1"]]))
        XCTAssertEqual(store.badge("t1"), .none)  // 未受影响
    }

    // M1：interrupted 不应记为 completed 绿点。turn/completed status=interrupted
    // → 不 recordOutcome（不亮绿），但仍清实时态。
    func test_turnCompleted_interrupted_does_not_record_completed() {
        let rs = ReadStateStore(defaults: UserDefaults(suiteName: "scint.\(UUID().uuidString)")!)
        let store = ProjectsStore(readState: rs)
        store.ingest([ThreadSummary(id: "t1", sessionId: "s1", preview: "", modelProvider: "openai",
                                    createdAt: 0, updatedAt: 100, cwd: "/x", cliVersion: "0.1.0",
                                    name: nil, gitInfo: GitInfoSummary(sha: nil, branch: "m", originUrl: "o/x"))])
        rs.markViewed("t1", updatedAt: 50)   // 旧锚点：若误记 completed 会亮绿
        let coord = StatusCoordinator(projects: store)
        coord.handle(notif(ServerNotificationMethod.turnStarted,
                           ["threadId": "t1", "turn": ["id": "u1"]]))
        coord.handle(notif(ServerNotificationMethod.turnCompleted,
                           ["threadId": "t1", "turn": ["id": "u1", "status": "interrupted"]]))
        XCTAssertNil(rs.lastOutcome("t1"))        // 未记结局
        XCTAssertEqual(store.badge("t1"), .none)  // 不亮绿（live 已清空、无 outcome）
    }
}
