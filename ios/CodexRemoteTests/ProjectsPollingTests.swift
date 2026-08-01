import XCTest
@testable import CodexRemote

@MainActor
final class ProjectsPollingTests: XCTestCase {
    /// startPolling 后按间隔重拉 thread/list；stopPolling 后停止。
    func test_polling_refreshes_then_stops() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)

        s.startPolling(intervalNanos: 30_000_000)   // 30ms 便于测试
        try await Task.sleep(nanoseconds: 100_000_000)
        let countAfterPolling = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThanOrEqual(countAfterPolling, 2, "应至少轮询重拉两次")

        s.stopPolling()
        try await Task.sleep(nanoseconds: 30_000_000)
        let base = await mock.sent.filter { $0.contains("thread/list") }.count
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(after, base, "stopPolling 后不应再拉")
    }

    /// 重复 startPolling 幂等（不叠加多个定时器）。
    func test_startPolling_idempotent() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)
        s.startPolling(intervalNanos: 30_000_000)
        s.startPolling(intervalNanos: 30_000_000)   // 第二次应无效
        try await Task.sleep(nanoseconds: 100_000_000)
        s.stopPolling()
        let count = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    /// #6：可见性前置——isVisible=false 时 startPolling 不启动（后台/视图消失场景）。
    func test_startPolling_skips_when_not_visible() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)

        s.startPolling(intervalNanos: 30_000_000, isVisible: false)   // 不可见 → 不应启动
        try await Task.sleep(nanoseconds: 120_000_000)
        let count = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(count, 0, "不可见时不应启动轮询")
    }

    /// 可见时正常启动（回归保护既有行为）。
    func test_startPolling_starts_when_visible() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)
        s.startPolling(intervalNanos: 30_000_000, isVisible: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        s.stopPolling()
        let count = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
