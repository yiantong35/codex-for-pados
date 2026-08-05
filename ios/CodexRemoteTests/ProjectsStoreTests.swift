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

    // #4 手动重连重绑：attach 新 rpc 后旧广播订阅被取消、新 client 被重订阅。
    // 复现——attach(rpcA) 后 attach(rpcB)；经 rpcB 真实流喂 thread/unarchived 广播，
    // 应在 rpcB 上发出 thread/list（旧实现 guard broadcastObserver==nil → 观察者仍绑 rpcA，
    // 重连后新连接的官方广播永不刷新列表）。
    func test_reSubscribes_broadcast_on_rpc_change() async throws {
        let mockA = MockTransport()
        await mockA.setAutoRespond(true)
        let rpcA = JSONRPCClient(transport: mockA)
        await rpcA.start()

        let mockB = MockTransport()
        await mockB.setAutoRespond(true)
        let rpcB = JSONRPCClient(transport: mockB)
        await rpcB.start()

        let s = ProjectsStore()
        await s.attach(rpc: rpcA)
        await s.attach(rpc: rpcB)   // 模拟完整重连：新 rpc 实例

        let before = await mockB.sent.filter { $0.contains("thread/list") }.count
        await mockB.feed(#"{"method":"thread/unarchived","params":{"threadId":"t1"}}"#)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await mockB.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThan(after, before)
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
        // 批次②：待审批计数改由 daemon ThreadStatus.waitingOnApproval 派生。
        s.handleStatusChanged(threadId: "a", status: .active(activeFlags: [.waitingOnApproval]))
        XCTAssertEqual(s.pendingApprovalCount(in: s.projects[0]), 1)
    }

    func testListParamsRequestsDesktopSource() {
        // session-management「桌面来源会话可见」：显式覆盖 sourceKinds。
        // 真实 ThreadSourceKind 桌面来源字符串为 "appServer"（见 protocol/ts/v2/ThreadSourceKind.ts）。
        let params = ProjectsStore.listParamsForDesktopVisibility()
        XCTAssertTrue(params.sourceKinds?.contains("appServer") ?? false)
    }

    // Task 0.5：新建会话 —— 发 thread/start，解析 {thread:{id}} 返回新 thread id。
    // rpc 显式传入（不经 attach——projects 实例生产中从未 attach，测试须走生产同款路径）。
    func test_createThread_returns_new_id_from_response() async {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setAutoRespondThreadStart(#"{"thread":{"id":"new-tid-1","sessionId":"new-tid-1","status":{"type":"idle"}}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        let newId = await s.createThread(rpc: rpc)
        XCTAssertEqual(newId, "new-tid-1", "createThread 应返回响应 thread.id")
    }

    // Task 0.5：响应缺 thread.id（畸形/拒绝）→ 返回 nil，不崩溃。
    func test_createThread_returns_nil_on_malformed_response() async {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setAutoRespondThreadStart(#"{"unexpected":true}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        let newId = await s.createThread(rpc: rpc)
        XCTAssertNil(newId, "响应无 thread.id 时应返回 nil")
    }

    // Task 0.5 防抖：创建进行中，第二次调用被拒（返回 nil，不发第二个 thread/start）。
    func test_createThread_debounces_concurrent_calls() async throws {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setAutoRespondThreadStart(#"{"thread":{"id":"new-tid-1"}}"#)
        await mock.setThreadStartDelay(300_000_000)   // 首个应答延迟 300ms，制造创建窗口且最终会回
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        // 第一次：延迟应答期间保持创建态
        async let first = s.createThread(rpc: rpc)
        try await Task.sleep(nanoseconds: 100_000_000)   // 100ms：请求已发、应答未到
        XCTAssertTrue(s.isCreatingThread, "创建进行中应置 isCreatingThread")

        // 第二次：应被防抖立即拒绝
        let second = await s.createThread(rpc: rpc)
        XCTAssertNil(second, "创建进行中第二次调用应返回 nil")

        // 第一次最终成功返回，创建态复位
        let firstId = await first
        XCTAssertEqual(firstId, "new-tid-1", "首个创建应正常返回新 id")
        XCTAssertFalse(s.isCreatingThread, "创建结束后 isCreatingThread 复位")

        let startCount = await mock.sent.filter { $0.contains("thread/start") }.count
        XCTAssertEqual(startCount, 1, "只应发出一个 thread/start（第二次被防抖拦下）")
    }

    // Task 0.5 节流：一次新建后 1s 内的再次调用被拒（治本机往返极快、串行快速连点建多个）。
    func test_createThread_throttles_rapid_serial_taps() async {
        var fakeNow = Date(timeIntervalSince1970: 1000)
        let s = ProjectsStore(now: { fakeNow })
        let mock = MockTransport()
        await mock.setAutoRespondThreadStart(#"{"thread":{"id":"tid-A"}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        // 第一次：成功
        let first = await s.createThread(rpc: rpc)
        XCTAssertEqual(first, "tid-A")

        // 300ms 后再点（本机往返已返回、并发标志已复位）→ 应被 2s 节流拦下
        fakeNow = Date(timeIntervalSince1970: 1000.3)
        let second = await s.createThread(rpc: rpc)
        XCTAssertNil(second, "2s 内再次新建应被节流拒绝")
        let count1 = await mock.sent.filter { $0.contains("thread/start") }.count
        XCTAssertEqual(count1, 1, "节流期内不应再发 thread/start")

        // 超过 2s 后再点 → 放行
        fakeNow = Date(timeIntervalSince1970: 1002.5)
        let third = await s.createThread(rpc: rpc)
        XCTAssertEqual(third, "tid-A", "超过节流窗后应放行新建")
        let count2 = await mock.sent.filter { $0.contains("thread/start") }.count
        XCTAssertEqual(count2, 2, "节流窗后应再发一个 thread/start")
    }

    // D5-a：未知 thread 的 thread/started → 触发重拉（rpc 提供该 thread 时被 ingest）
    func test_threadStarted_unknown_triggers_reload() async {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setThreadListResponse(#"{"data":[{"id":"b","sessionId":"b","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":5,"cwd":"/Volumes/mount","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#)
        let rpc = JSONRPCClient(transport: mock); await mock.setAutoRespond(true); await rpc.start()
        await s.attach(rpc: rpc)
        let n = JSONRPCNotification(method: ServerNotificationMethod.threadStarted,
            params: AnyCodable(["threadId": "b"]))
        await s.handleThreadStarted(n)
        XCTAssertTrue(s.allThreadsSorted.contains { $0.id == "b" }, "未知 thread 应经重拉出现")
    }

    // D5-a：已存在则不重复（不重拉）
    func test_threadStarted_broadcast_dedupes() async {
        let s = ProjectsStore()
        s.ingest([ thread("a", cwd: "/repo/x", updatedAt: 1, origin: "o/x", git: true) ])
        let n = JSONRPCNotification(method: ServerNotificationMethod.threadStarted,
            params: AnyCodable(["threadId": "a", "cwd": "/repo/x", "updatedAt": 9.0]))
        await s.handleThreadStarted(n)
        XCTAssertEqual(s.allThreadsSorted.filter { $0.id == "a" }.count, 1, "已存在不应重复插入")
    }
}
