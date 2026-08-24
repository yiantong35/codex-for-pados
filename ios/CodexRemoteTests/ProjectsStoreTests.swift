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

    // D4:分类不改算法——gitInfo≠nil(cwd 在 git 仓库内)→ 归对应项目组;gitInfo=nil → 游离对话。
    // cwd 正确后(Task 1/2/4)归组自然与 desktop 一致;分类正确性是 cwd 正确性的结果。
    func test_ingest_gitInfo_drives_project_vs_loose() {
        let s = ProjectsStore()
        s.ingest([
            thread("p", cwd: "/repo/web-dev", updatedAt: 10, origin: "o/web", git: true), // gitInfo≠nil → 项目
            thread("l", cwd: "/Users/me", updatedAt: 20),                                  // gitInfo=nil → 游离
        ])
        XCTAssertEqual(s.projects.map(\.id), ["o/web"], "有 gitInfo 应归入以 originUrl 为键的项目组")
        XCTAssertEqual(s.projects.first?.threads.map(\.id), ["p"])
        XCTAssertEqual(s.looseConversations.map(\.id), ["l"], "无 gitInfo 应留在游离对话")
    }

    func test_ingest_deduplicates_overlapping_pages_by_thread_id() {
        let s = ProjectsStore()
        s.ingest([
            thread("same", cwd: "/old", updatedAt: 10),
            thread("same", cwd: "/new", updatedAt: 20),
            thread("other", cwd: "/other", updatedAt: 15),
        ])

        XCTAssertEqual(s.allThreadsSorted.map(\.id), ["same", "other"])
        XCTAssertEqual(s.allThreadsSorted.first?.cwd, "/new")
    }

    // #7：会话列表分页——loadFromServer 应跟随 nextCursor 翻页，合并全部页后 ingest，
    // 而非只读首页 100 条（重连恢复也只读首页 → 100 条外的活跃会话永不出现）。
    func test_loadFromServer_follows_nextCursor_paginates_all_pages() async throws {
        let mock = MockTransport()
        // 首页（cursor "" ）返回 a + nextCursor "p2"；第二页（cursor "p2"）返回 b + nextCursor null。
        let page1 = #"{"data":[{"id":"a","sessionId":"a","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":10,"cwd":"/repo/x","cliVersion":"0.133.0","name":null,"gitInfo":{"sha":null,"branch":"main","originUrl":"o/x"}}],"nextCursor":"p2","backwardsCursor":null}"#
        let page2 = #"{"data":[{"id":"b","sessionId":"b","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":20,"cwd":"/Volumes/mount","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#
        await mock.setThreadListPages(["": page1, "p2": page2])
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        let s = ProjectsStore()
        await s.loadFromServer(rpc: rpc)

        // 两页均应被 ingest：第 2 页的 loose 会话 b 只有跟随 nextCursor 才会出现。
        XCTAssertEqual(s.projects.count, 1, "第 1 页项目 x 应在")
        XCTAssertEqual(s.looseConversations.map(\.id), ["b"], "第 2 页 loose 会话 b 须经翻页才出现")
        // 至少发出两次 thread/list（首页 + 跟随 nextCursor 的第二页）。
        let listCalls = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThanOrEqual(listCalls, 2, "应跟随 nextCursor 翻页而非只读首页")
        XCTAssertEqual(s.loadState, .loaded)
    }

    func test_firstPageFailure_exposesRetryableFailureState() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.failNextThreadListRequests(1)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let s = ProjectsStore()

        await s.loadFromServer(rpc: rpc)

        XCTAssertEqual(s.loadState, .failed)
        XCTAssertTrue(s.allThreadsSorted.isEmpty)
    }

    func test_loadFromServer_stopsOnRepeatedCursor() async throws {
        let mock = MockTransport()
        let page = #"{"data":[],"nextCursor":"loop","backwardsCursor":null}"#
        await mock.setThreadListPages(["": page, "loop": page])
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let s = ProjectsStore()

        await s.loadFromServer(rpc: rpc)

        let calls = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(calls, 2, "重复 cursor 应立即停止，而不是请求满 50 页")
        XCTAssertEqual(s.loadState, .loaded)
    }

    func test_loadFromServer_laterPageFailurePreservesExistingTail() async throws {
        let s = ProjectsStore()
        s.ingest([thread("deep", cwd: "/repo/deep", updatedAt: 1)])
        let mock = MockTransport()
        let page1 = #"{"data":[{"id":"recent","sessionId":"recent","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":20,"cwd":"/repo/recent","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":"p2","backwardsCursor":null}"#
        await mock.setThreadListPages(["": page1])
        await mock.failThreadListRequests(cursors: ["p2"])
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        await s.loadFromServer(rpc: rpc)

        XCTAssertEqual(Set(s.allThreadsSorted.map(\.id)), Set(["recent", "deep"]),
                       "后续页瞬时失败只能刷新已取到的前缀，不能删除旧快照尾部")
        XCTAssertEqual(s.loadState, .loaded)
    }

    func test_loadFromServer_completeSnapshotStillRemovesMissingThreads() async throws {
        let s = ProjectsStore()
        s.ingest([thread("deleted", cwd: "/repo/deleted", updatedAt: 1)])
        let mock = MockTransport()
        await mock.setThreadListResponse(#"{"data":[{"id":"current","sessionId":"current","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":20,"cwd":"/repo/current","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#)
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        await s.loadFromServer(rpc: rpc)

        XCTAssertEqual(s.allThreadsSorted.map(\.id), ["current"],
                       "明确到达分页末尾时应继续采用权威替换语义")
    }

    func test_reconnectAllowsNewFullSyncWhileOldResponseIsLost() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ProjectsStore(requestTimeoutNanos: 100_000_000)
        await store.attach(rpc: rpc)

        let stale = Task { await store.loadFromServer(rpc: rpc) }
        try await waitUntil {
            await mock.sent.filter { $0.contains("thread/list") }.count == 1
        }

        // Physical reconnects reuse this RPC actor. Re-attaching must invalidate the stale sync
        // gate immediately so the ready channel can issue a fresh authoritative request.
        await store.attach(rpc: rpc)
        await mock.setThreadListResponse(#"{"data":[{"id":"fresh","sessionId":"fresh","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":20,"cwd":"/repo/current","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#)
        await mock.setAutoRespond(true)
        await store.loadFromServer(rpc: rpc)

        XCTAssertEqual(store.allThreadsSorted.map(\.id), ["fresh"])
        let requestCount = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(requestCount, 2)
        await stale.value
        let supersededReconnectCount = await mock.triggerReconnectCount
        XCTAssertEqual(supersededReconnectCount, 0,
                       "superseded request timeout must not disrupt the recovered connection")
    }

    func test_currentRequestTimeoutReleasesSyncAndTriggersReconnect() async {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ProjectsStore(requestTimeoutNanos: 20_000_000)
        await store.attach(rpc: rpc)

        await store.loadFromServer(rpc: rpc)

        XCTAssertEqual(store.loadState, .failed)
        let reconnectCount = await mock.triggerReconnectCount
        XCTAssertEqual(reconnectCount, 1)
        await mock.setAutoRespond(true)
        await store.loadFromServer(rpc: rpc)
        let requestCount = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(requestCount, 2,
                       "timeout must release the full-sync gate for a later retry")
    }

    func test_refreshRecentPage_mergesWithoutDeletingDeepHistory() async throws {
        let s = ProjectsStore()
        s.ingest([thread("deep", cwd: "/repo/deep", updatedAt: 1)])
        let mock = MockTransport()
        await mock.setThreadListResponse(#"{"data":[{"id":"recent","sessionId":"recent","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":20,"cwd":"/repo/recent","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":"p2","backwardsCursor":null}"#)
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        let succeeded = await s.refreshRecentPage(rpc: rpc)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(Set(s.allThreadsSorted.map(\.id)), Set(["recent", "deep"]),
                       "最近页刷新不得删除首页之外的深历史")
        let calls = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(calls, 1, "最近页刷新只能请求首页")
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

    // D2：项目内新建以 cwd=project.cwd 发 thread/start，发出帧须含 "cwd":"<project.cwd>"。
    // 锁定 store 侧编码契约（D2 UI 接线在 SidebarView，见结构性断言）；mock rpc 捕获发出帧。
    func test_createThread_encodes_cwd_in_frame() async {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setAutoRespondThreadStart(#"{"thread":{"id":"tid"}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        _ = await s.createThread(rpc: rpc, cwd: "/repo/web-dev")

        let sent = await mock.sent
        XCTAssertTrue(
            sent.contains { $0.contains("thread/start") && $0.contains("\"cwd\":\"/repo/web-dev\"") },
            "项目内新建应携带 cwd=project.cwd；实际：\(sent)"
        )
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
        XCTAssertNotNil(s.createThreadError)
    }

    func testSelectionClearsOnlyAfterLoadedListRemovesThread() {
        XCTAssertEqual(RootSplitView.resolvedSelection(
            current: "t1", availableIDs: [], loadState: .idle), "t1")
        XCTAssertEqual(RootSplitView.resolvedSelection(
            current: "t1", availableIDs: ["t1"], loadState: .loaded), "t1")
        XCTAssertNil(RootSplitView.resolvedSelection(
            current: "t1", availableIDs: ["t2"], loadState: .loaded))
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
        XCTAssertNotNil(s.createThreadError, "节流必须给 UI 可展示反馈，不能静默无响应")
        let count1 = await mock.sent.filter { $0.contains("thread/start") }.count
        XCTAssertEqual(count1, 1, "节流期内不应再发 thread/start")

        // 超过 2s 后再点 → 放行
        fakeNow = Date(timeIntervalSince1970: 1002.5)
        let third = await s.createThread(rpc: rpc)
        XCTAssertEqual(third, "tid-A", "超过节流窗后应放行新建")
        let count2 = await mock.sent.filter { $0.contains("thread/start") }.count
        XCTAssertEqual(count2, 2, "节流窗后应再发一个 thread/start")
    }

    func test_fetchGoal_withoutConnection_throws_insteadOfReturningNoGoal() async {
        let store = ProjectsStore()
        do {
            _ = try await store.fetchGoal(threadId: "thread")
            XCTFail("断线读取 Goal 不得伪装成合法的 goal=nil")
        } catch {
            XCTAssertTrue(error is TransportError)
        }
    }

    // D5-a：未知 thread 的 thread/started → 触发重拉（rpc 提供该 thread 时被 ingest）
    func test_threadStarted_unknown_triggers_reload() async {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setThreadListResponse(#"{"data":[{"id":"b","sessionId":"b","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":5,"cwd":"/Volumes/mount","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#)
        let rpc = JSONRPCClient(transport: mock); await mock.setAutoRespond(true); await rpc.start()
        await s.attach(rpc: rpc)
        let n = JSONRPCNotification(method: ServerNotificationMethod.threadStarted,
            params: AnyCodable(["thread": ["id": "b"]]))
        await s.handleThreadStarted(n)
        XCTAssertTrue(s.allThreadsSorted.contains { $0.id == "b" }, "未知 thread 应经重拉出现")
    }

    // D5-a：已存在则不重复（不重拉）
    func test_threadStarted_broadcast_dedupes() async {
        let s = ProjectsStore()
        s.ingest([ thread("a", cwd: "/repo/x", updatedAt: 1, origin: "o/x", git: true) ])
        let n = JSONRPCNotification(method: ServerNotificationMethod.threadStarted,
            params: AnyCodable(["thread": ["id": "a", "cwd": "/repo/x", "updatedAt": 9.0]]))
        await s.handleThreadStarted(n)
        XCTAssertEqual(s.allThreadsSorted.filter { $0.id == "a" }.count, 1, "已存在不应重复插入")
    }

    func test_threadStarted_realPayloadFlowsThroughProductionObserver() async throws {
        let s = ProjectsStore()
        let mock = MockTransport()
        await mock.setThreadListResponse(#"{"data":[{"id":"real","sessionId":"real","preview":"","modelProvider":"openai","createdAt":0,"updatedAt":5,"cwd":"/Volumes/mount","cliVersion":"0.133.0","name":null,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}"#)
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        await s.attach(rpc: rpc)

        await mock.feed(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"real","cwd":"/Volumes/mount","turns":[]}}}"#)
        try await waitUntil { s.allThreadsSorted.contains { $0.id == "real" } }
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out")
    }
}
