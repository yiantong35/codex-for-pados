import XCTest
@testable import CodexRemote

@MainActor
final class ProjectsStoreTests: XCTestCase {
    private func thread(_ id: String, cwd: String, updatedAt: Double,
                        origin: String? = nil, git: Bool = false) -> ThreadSummary {
        ThreadSummary(id: id, sessionId: id, preview: "", modelProvider: "openai",
                      createdAt: 0, updatedAt: updatedAt, cwd: cwd, cliVersion: "0.133.0",
                      name: nil, gitInfo: git ? GitInfoSummary(sha: nil, branch: "main", originUrl: origin) : nil)
    }

    func test_ingest_classifies_project_vs_loose() {
        let s = ProjectsStore()
        s.ingest([
            thread("a", cwd: "/repo/web-dev", updatedAt: 10, origin: "o/web", git: true),
            thread("b", cwd: "/repo/web-dev-wt", updatedAt: 20, origin: "o/web", git: true), // 同 origin → 同项目
            thread("c", cwd: "/repo/api", updatedAt: 30, origin: "o/api", git: true),
            thread("d", cwd: "/Volumes/mount", updatedAt: 40), // 无 git → loose
        ])
        XCTAssertEqual(s.projects.count, 2)                 // web + api
        XCTAssertEqual(s.looseConversations.map(\.id), ["d"])
        XCTAssertTrue(s.isGrouped)                          // ≥2 项目
        // 项目间按组内最近 updatedAt 倒序：api(30) 在 web(20) 前
        XCTAssertEqual(s.projects.first?.threads.map(\.id), ["c"])
        // 项目内按 updatedAt 倒序：web 组 b(20) 在 a(10) 前
        XCTAssertEqual(s.projects.last?.threads.map(\.id), ["b", "a"])
    }

    func test_isGrouped_false_when_single_project() {
        let s = ProjectsStore()
        s.ingest([ thread("a", cwd: "/repo/x", updatedAt: 1, origin: "o/x", git: true),
                   thread("d", cwd: "/Volumes/mount", updatedAt: 2) ])
        XCTAssertFalse(s.isGrouped)                         // 仅 1 项目 → 平铺
        XCTAssertEqual(s.allThreadsSorted.map(\.id), ["d", "a"])  // 全列表按 updatedAt 倒序
    }

    func test_pendingApprovalCount_per_project() {
        let s = ProjectsStore()
        s.ingest([ thread("a", cwd: "/repo/x", updatedAt: 1, origin: "o/x", git: true),
                   thread("b", cwd: "/repo/x", updatedAt: 2, origin: "o/x", git: true) ])
        s.setPendingApproval(threadId: "a", pending: true)
        XCTAssertEqual(s.pendingApprovalCount(in: s.projects[0]), 1)
    }

    func testListParamsRequestsDesktopSource() {
        // session-management「桌面来源会话可见」：显式覆盖 sourceKinds。
        // 真实 ThreadSourceKind 桌面来源字符串为 "appServer"（见 protocol/ts/v2/ThreadSourceKind.ts）。
        let params = ProjectsStore.listParamsForDesktopVisibility()
        XCTAssertTrue(params.sourceKinds?.contains("appServer") ?? false)
    }

    func testPendingApprovalBadge() {
        let store = ProjectsStore()
        store.ingest([thread("a", cwd: "/r", updatedAt: 2, origin: "o/r", git: true)])
        store.setPendingApproval(threadId: "a", pending: true)
        XCTAssertTrue(store.hasPendingApproval("a"))
        store.setPendingApproval(threadId: "a", pending: false)
        XCTAssertFalse(store.hasPendingApproval("a"))
    }

    // MARK: - sidebar-status-badges：liveStatus + badge() 组合

    private func storeWithReadState() -> (ProjectsStore, ReadStateStore) {
        let rs = ReadStateStore(defaults: UserDefaults(suiteName: "ps.\(UUID().uuidString)")!)
        let s = ProjectsStore(readState: rs)
        return (s, rs)
    }

    func test_setLiveStatus_drives_badge_running() {
        let (s, _) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        s.setLiveStatus("a", .running)
        XCTAssertEqual(s.badge("a"), .running)
    }

    func test_setLiveStatus_waiting_drives_blue() {
        let (s, _) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        s.setLiveStatus("a", .waiting)
        XCTAssertEqual(s.badge("a"), .waiting)
    }

    // 未读完成：live=none + outcome=completed + updatedAt > viewedAt(默认 ∞→需先有 outcome 且未 markViewed)
    func test_unread_completed_when_outcome_recorded_and_not_viewed() {
        let (s, rs) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        // 模拟 turn/completed 记录结局，但 viewedAt 默认 ∞ → 仍判已读（B2）
        rs.recordOutcome("a", outcome: .completed)
        XCTAssertEqual(s.badge("a"), .none)
        // 一旦 markViewed 把锚点设到过去，再来新 updatedAt 才算未读
        rs.markViewed("a", updatedAt: 5)   // 上次看的是 ts=5
        XCTAssertEqual(s.badge("a"), .unreadCompleted)  // updatedAt=10 > 5
    }

    // B3：自己发消息→点击已 markViewed 到当前 updatedAt → 不误亮
    func test_markViewed_clears_unread() {
        let (s, rs) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        rs.recordOutcome("a", outcome: .failed)
        rs.markViewed("a", updatedAt: 5)
        XCTAssertEqual(s.badge("a"), .unreadFailed)
        s.markViewed("a")   // 标记到当前 updatedAt=10
        XCTAssertEqual(s.badge("a"), .none)  // 10 > 10 false
    }

    // B7：断线不清空 liveStatus（仅验证 setLiveStatus 不会被任何清空逻辑动到——无 clear API）
    func test_liveStatus_persists_until_overwritten() {
        let (s, _) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        s.setLiveStatus("a", .running)
        s.setLiveStatus("a", .none)  // 只有显式 setNone 才变
        XCTAssertEqual(s.badge("a"), .none)
    }

    // ingest 回填：带 active+waitingOnApproval 的 status → badge=waiting
    func test_ingest_backfills_liveStatus_from_status_field() {
        let (s, _) = storeWithReadState()
        var t = thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)
        t.status = ThreadStatusSummary(type: "active", activeFlags: ["waitingOnApproval"])
        s.ingest([t])
        XCTAssertEqual(s.badge("a"), .waiting)
    }

    func test_badge_unknown_thread_is_none() {
        let (s, _) = storeWithReadState()
        XCTAssertEqual(s.badge("missing"), .none)
    }

    // MARK: - H1+M3：选中会话恒为已读（设计 B4）

    // 选中会话即使 outcome=completed 且 updatedAt>旧 viewedAt 也不显示未读
    func test_selected_thread_never_unread_even_with_completed_outcome() {
        let (s, rs) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        rs.recordOutcome("a", outcome: .completed)
        rs.markViewed("a", updatedAt: 5)            // 旧锚点 → 正常会判未读
        XCTAssertEqual(s.badge("a"), .unreadCompleted)  // 未选中 → 未读绿
        s.setSelected("a")                          // 选中
        XCTAssertEqual(s.badge("a"), .none)         // 选中会话恒已读
    }

    // 选中会话刷新（ingest 整表替换 updatedAt）后仍不显示未读
    func test_selected_thread_stays_read_after_ingest_refresh() {
        let (s, rs) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        rs.recordOutcome("a", outcome: .completed)
        rs.markViewed("a", updatedAt: 10)
        s.setSelected("a")
        // 刷新：updatedAt 推进到 20（turn 完成但用户全程在看）
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 20, origin: "o/x", git: true)])
        XCTAssertEqual(s.badge("a"), .none)         // 仍已读（ingest 重锚选中会话）
    }

    // 离开选中会话（setSelected 别的 id）后，该会话按正常未读判定（离开时以最后所见 updatedAt 为锚）
    func test_leaving_selected_thread_anchors_to_last_seen() {
        let (s, rs) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        rs.recordOutcome("a", outcome: .completed)
        rs.markViewed("a", updatedAt: 10)
        s.setSelected("a")
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 20, origin: "o/x", git: true)])  // 在看时刷新→重锚 20
        s.setSelected("b")                          // 离开 a
        XCTAssertEqual(s.badge("a"), .none)         // updatedAt(20)==viewedAt(20) → 不未读
        // 离开后新活动（updatedAt 推进）才算未读
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 30, origin: "o/x", git: true)])
        XCTAssertEqual(s.badge("a"), .unreadCompleted)  // 30 > 20
    }

    // 选中会话仍正常显示 live 态（running/waiting）
    func test_selected_thread_still_shows_live_status() {
        let (s, _) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        s.setSelected("a")
        s.setLiveStatus("a", .running)
        XCTAssertEqual(s.badge("a"), .running)
    }

    // MARK: - M2：审批+完成竞态单一真相源

    // setPendingApproval(true) 后即使 setLiveStatus(.none)，badge 仍 .waiting
    func test_pendingApproval_is_single_source_of_truth_for_waiting() {
        let (s, _) = storeWithReadState()
        s.ingest([thread("a", cwd: "/repo/x", updatedAt: 10, origin: "o/x", git: true)])
        s.setPendingApproval(threadId: "a", pending: true)
        s.setLiveStatus("a", .none)                 // 完成事件清实时态
        XCTAssertEqual(s.badge("a"), .waiting)      // 待批准仍在 → 强制蓝
    }
}
