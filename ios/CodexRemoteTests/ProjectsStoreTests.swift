import XCTest
@testable import CodexRemote

@MainActor
final class ProjectsStoreTests: XCTestCase {
    func testGroupsThreadsByCwd() {
        let store = ProjectsStore()
        store.ingest([
            ThreadSummary(id: "a", sessionId: "s", preview: "p1", modelProvider: "openai",
                          createdAt: 1, updatedAt: 2, cwd: "/repo/x", cliVersion: "0", name: "A"),
            ThreadSummary(id: "b", sessionId: "s", preview: "p2", modelProvider: "openai",
                          createdAt: 1, updatedAt: 3, cwd: "/repo/x", cliVersion: "0", name: nil),
            ThreadSummary(id: "c", sessionId: "s", preview: "p3", modelProvider: "openai",
                          createdAt: 1, updatedAt: 4, cwd: "/repo/y", cliVersion: "0", name: "C"),
        ])
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.projects.first(where: { $0.cwd == "/repo/x" })?.threads.count, 2)
    }

    func testListParamsRequestsDesktopSource() {
        // session-management「桌面来源会话可见」：显式覆盖 sourceKinds。
        // 真实 ThreadSourceKind 桌面来源字符串为 "appServer"（见 protocol/ts/v2/ThreadSourceKind.ts）。
        let params = ProjectsStore.listParamsForDesktopVisibility()
        XCTAssertTrue(params.sourceKinds?.contains("appServer") ?? false)
    }

    func testPendingApprovalBadge() {
        let store = ProjectsStore()
        store.ingest([ThreadSummary(id: "a", sessionId: "s", preview: "p", modelProvider: "o",
                       createdAt: 1, updatedAt: 2, cwd: "/r", cliVersion: "0", name: "A")])
        store.setPendingApproval(threadId: "a", pending: true)
        XCTAssertTrue(store.hasPendingApproval("a"))
        store.setPendingApproval(threadId: "a", pending: false)
        XCTAssertFalse(store.hasPendingApproval("a"))
    }
}
