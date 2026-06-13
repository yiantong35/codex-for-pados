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
}
