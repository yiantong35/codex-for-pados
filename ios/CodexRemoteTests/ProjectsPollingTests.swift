import XCTest
@testable import CodexRemote

@MainActor
final class ProjectsPollingTests: XCTestCase {
    func test_pollingRequestsOnlyFirstPage() async throws {
        let s = ProjectsStore()
        let mock = MockTransport()
        let page1 = #"{"data":[],"nextCursor":"p2","backwardsCursor":null}"#
        let page2 = #"{"data":[],"nextCursor":null,"backwardsCursor":null}"#
        await mock.setThreadListPages(["": page1, "p2": page2])
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)

        s.startPolling(intervalNanos: 20_000_000)
        try await Task.sleep(for: .milliseconds(70))
        s.stopPolling()

        let frames = await mock.sent.filter { $0.contains("thread/list") }
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertFalse(frames.contains { $0.contains(#""cursor":"p2""#) },
                       "常态轮询不得沿 nextCursor 做完整分页")
    }

    func test_attachNewRPCStopsOldPollingAndContinuesOnNewRPC() async throws {
        let s = ProjectsStore()
        let mockA = MockTransport(); await mockA.setAutoRespond(true)
        let rpcA = JSONRPCClient(transport: mockA); await rpcA.start()
        let mockB = MockTransport(); await mockB.setAutoRespond(true)
        let rpcB = JSONRPCClient(transport: mockB); await rpcB.start()
        await s.attach(rpc: rpcA)
        s.startPolling(intervalNanos: 20_000_000)
        try await Task.sleep(for: .milliseconds(60))

        await s.attach(rpc: rpcB)
        let aAfterRebind = await mockA.sent.filter { $0.contains("thread/list") }.count
        try await Task.sleep(for: .milliseconds(70))
        s.stopPolling()

        let aFinal = await mockA.sent.filter { $0.contains("thread/list") }.count
        let bFinal = await mockB.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(aFinal, aAfterRebind, "重绑后旧 RPC 不得继续收到轮询")
        XCTAssertGreaterThanOrEqual(bFinal, 2, "新 RPC 应接管后续轮询")
    }

    func test_pollingBacksOffAndResetsAfterSuccess() async throws {
        let sleeps = PollSleepRecorder()
        let s = ProjectsStore(pollSleep: { nanos in await sleeps.record(nanos) })
        let mock = MockTransport(); await mock.setAutoRespond(true)
        await mock.failNextThreadListRequests(6)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)

        s.startPolling(intervalNanos: 30, maxIntervalNanos: 300)
        try await waitUntil { await sleeps.values.count >= 8 }
        s.stopPolling()

        let values = Array(await sleeps.values.prefix(8))
        XCTAssertEqual(values, [30, 60, 120, 240, 300, 300, 300, 30],
                       "失败应指数退避并封顶 5min，成功后重置基线")
    }

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

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil 超时")
    }
}

actor PollSleepRecorder {
    private(set) var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
}
