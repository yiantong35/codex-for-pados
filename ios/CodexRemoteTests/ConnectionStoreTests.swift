import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

final class ConnectionStoreTests: XCTestCase {
    // relay-only：connect() 前置校验只看 relay 配对载荷非空（relayURL），
    // 与本机密钥无关，故 .stub 连接直接进入注入的 mock 工厂，无需 setUp 预置密钥。

    func testHandshakeReachesReady() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        // 服务端在收到 initialize 后按其实际唯一 id 回响应（唯一 string id，不能再硬编码 id:1）。
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)            // fire-and-forget，结果经 phase 反映
        try await waitUntil { await store.phase == .ready }
        // 发出了 initialize 与 initialized
        let sent = await mock.sent
        XCTAssertTrue(sent.contains { $0.contains("initialize") })
        XCTAssertTrue(sent.contains { $0.contains(#""method":"initialized""#) })
        // 服务端信息已解析
        let info = await store.serverInfo
        XCTAssertEqual(info?.userAgent, "codex")
    }

    // spike 实测坐实：官方 ws app-server 的 initialize 是连接级（per-connection），
    // iPad 自己的连接发 initialize 永远各自成功，绝不会拿 -32600 Already initialized。
    // 旧「Already initialized 容忍」分支是针对自建 daemon 进程级单次语义的死代码，已删除。
    // 新行为：initialize 失败（含收到 -32600 error）就是失败，按正常错误处理落 .failed，
    // 不再把 Already-initialized 当作握手成功。
    func testInitializeErrorReachesFailed() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","error":{"code":-32600,"message":"Already initialized"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil {
            if case .failed = await store.phase { return true } else { return false }
        }
        // 不应到达 ready：initialize 错误 = 连接失败。
        if case .ready = await store.phase { XCTFail("initialize 收到 -32600 不应视为 ready") }
    }

    // F6：doEstablish 内 transport 与 JSON-RPC 接收循环在 initialize 之前已启动、inFlightTransport
    // 已设。initialize 抛错时必须 fail-closed 显式清理（client 停 + transport 关 + inFlightTransport
    // 清空），不能只落 phase=.failed 而遗留打开的连接/接收任务。用默认 20s 超时（不注入短超时）：
    // 3s 测试窗口内超时兜底不会触发（!phase.isSettled 在 .failed 后为 false），证明清理来自失败路径
    // 本身，而非超时兜底路径（那条已被 testConnectTimeoutClosesInFlightTransport 覆盖）。
    func testInitializeFailureClosesTransportAndClearsInFlight() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","error":{"code":-32600,"message":"Already initialized"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil {
            if case .failed = await store.phase { return true } else { return false }
        }
        // fail-closed 清理见证：在途 transport 已关闭 + inFlightTransport 已清空。
        // bug 版本（catch 只置 phase）下这两条都会失败：closeCount 停在 0、inFlight 仍非 nil。
        let closeCount = await mock.closeCount
        XCTAssertGreaterThanOrEqual(closeCount, 1, "initialize 失败应关闭在途 transport，实际 closeCount=\(closeCount)")
        let inFlight = await store.inFlightTransportForTesting
        XCTAssertNil(inFlight, "initialize 失败应清空 inFlightTransport，避免泄漏")
    }

    /// relay 配对载荷缺失（relayURL 为空）时 connect 不调 transportFactory，直接落 .failed。
    @MainActor
    func testIncompleteConfigDoesNotConnect() async throws {
        let calledBox = CallBox()
        let store = ConnectionStore(transportFactory: { _ in
            await calledBox.mark()
            throw TransportError.notConnected
        })
        // relayURL 为空 → 前置校验拒绝，不应进入工厂。
        store.connect(config: .init(relayURL: "", relaySessionId: "", relayDevIdentityPubB64: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        let called = await calledBox.value
        XCTAssertFalse(called, "必填项缺失不应调用 transportFactory")
        if case .failed = store.phase {} else { XCTFail("必填项缺失应落 .failed，实际 \(store.phase)") }
    }

    // snapshotNeeded 控制信号已随去 envelope 移除（设计 D1）；重连后会话恢复改由
    // §5 经 thread/loaded/list + thread/resume 完成，相应测试归属 §5。

    /// §5 修正：首次连接成功（initialize 完成、phase=.ready）后也应触发一次 resumeHandler
    /// （连接级恢复任务），以「连上自动订阅全部活跃 thread」对齐需求——
    /// 不能只在 WSTransport 物理重连的 .ready 上 rejoin（首连不经 control() 的 .ready）。
    /// 真实接线顺序：connect() 先发起，ConversationView 的 .task 在 rpc 就绪后才 setResumeHandler，
    /// 故 handler 可能晚于 .ready 注册——本测试模拟该顺序，断言 handler 仍被触发恰好一次。
    func testInitialConnectAlsoRejoins() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })

        // 后台模拟服务端：对 initialize 回响应使握手到达 .ready。
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }

        let fired = FireBox()
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        // 模拟 ConversationView：rpc 就绪后才注册 resumeHandler（晚于 .ready）。
        await store.setResumeHandler { await fired.bump() }

        // 首连 + handler 注册后，应触发恰好一次 resume（rejoin）。
        try await waitUntil { await fired.count >= 1 }
        let count = await fired.count
        XCTAssertEqual(count, 1, "首连成功后 resumeHandler 应被触发恰好一次，实际 \(count)")
    }

    // #1：远端接受 exec 但永不发 101、也不关流时，doEstablish 会永久挂在 awaitHandshake()。
    // 硬超时作废本 attempt 时，必须关闭在途 transport（否则 SSH 连接 + 挂起任务泄漏）。
    // 断言：失效后 transport.close() 被调用恰好一次，且 store 落 .failed。
    func testConnectTimeoutClosesInFlightTransport() async throws {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)   // 握手永不完成，doEstablish 挂在 awaitHandshake
        // 注入极短超时（120ms），避免真的等 20 秒。
        let store = await ConnectionStore(transportFactory: { _ in mock },
                                          connectTimeoutNanos: 120_000_000)
        await store.connect(config: .stub)
        // 超时后应落 .failed。
        try await waitUntil {
            if case .failed = await store.phase { return true } else { return false }
        }
        // 关键断言：在途 transport 被关闭恰好一次。
        try await waitUntil { await mock.closeCount >= 1 }
        let count = await mock.closeCount
        XCTAssertEqual(count, 1, "超时作废在途 attempt 时应关闭 transport 恰好一次，实际 \(count)")
    }

    /// #7：首连握手在途时退后台 → 在途 transport 被取消（close 恰好一次）、inFlight 清空、phase 非 .ready。
    func testBackgroundDuringInFlightConnectCancelsTransport() async throws {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)               // 握手永不完成 → doEstablish 挂在 awaitHandshake
        // 用较长超时排除超时兜底干扰：本用例要证明取消来自退后台而非超时。
        let store = await ConnectionStore(transportFactory: { _ in mock },
                                          connectTimeoutNanos: 20_000_000_000)
        await store.connect(config: .stub)
        // 等 inFlightTransport 就位（doEstablish 已设 inFlightTransport 后挂起）。
        try await waitUntil { await store.inFlightTransportForTesting != nil }

        await store.setForeground(false)                 // 退后台：应取消在途首连

        try await waitUntil { await mock.closeCount >= 1 }
        let count = await mock.closeCount
        XCTAssertEqual(count, 1, "退后台应关闭在途 transport 恰好一次，实际 \(count)")
        let inflight = await store.inFlightTransportForTesting
        XCTAssertNil(inflight, "退后台取消后应清空 inFlightTransport，不泄漏")
        if case .ready = await store.phase { XCTFail("在途首连被后台取消，不应到达 .ready") }
        // 退后台取消必须落终态 .disconnected：否则 connect 的 stale-attempt guard 提前 return，
        // phase 卡在 .connecting → UI 转圈禁用、needsConnect/自动重连门失效，回前台无从重试。
        let phase = await store.phase
        XCTAssertEqual(phase, .disconnected, "退后台取消应落 .disconnected 以允许回前台重连")
    }

    /// #7：回前台重试成功 —— 首连期间退后台取消在途 transport 后，回前台再 connect() 应走正常
    /// 握手路径到达 .ready（本 change 不改正常路径）。用二连发工厂：首个 mock 握手挂起（被后台取消），
    /// 第二个 mock 不阻塞握手、正常喂 initialize 响应。
    func testForegroundReturnRetryReachesReady() async throws {
        let mock1 = MockTransport()
        await mock1.setBlockHandshake(true)              // 首连：握手永不完成 → 挂在 awaitHandshake
        let mock2 = MockTransport()                      // 重试：不阻塞握手
        let factory = MockSequenceFactory(mocks: [mock1, mock2])
        let store = await ConnectionStore(transportFactory: { _ in await factory.next() },
                                          connectTimeoutNanos: 20_000_000_000)

        // 第一次连接：等在途就位后退后台取消。
        await store.connect(config: .stub)
        try await waitUntil { await store.inFlightTransportForTesting != nil }
        await store.setForeground(false)
        try await waitUntil { await mock1.closeCount >= 1 }
        if case .ready = await store.phase { XCTFail("在途首连被后台取消，不应到达 .ready") }

        // 回前台后重试：第二个 mock 走正常握手（喂 initialize 响应）到达 .ready。
        await store.setForeground(true)
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock2.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock2.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        let info = await store.serverInfo
        XCTAssertEqual(info?.userAgent, "codex", "回前台重试应正常握手到达 .ready")
    }

    // MARK: - D2 resume 订阅表（多订阅者）

    /// D2：主对话与侧聊各自注册恢复回调，物理重连 .ready 时两者都被触发（后者不覆盖前者）。
    func test_multipleResumeHandlers_bothTriggeredOnReconnect() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        try await driveToReady(store: store, mock: mock)

        let a = FireBox(); let b = FireBox()
        _ = await store.addResumeHandler { await a.bump() }
        _ = await store.addResumeHandler { await b.bump() }
        // 首连补触发各恰一次（已 ready 时注册）。
        try await waitUntil { let ca = await a.count; let cb = await b.count; return ca >= 1 && cb >= 1 }

        // 物理重连 .ready：遍历触发全部订阅者。
        await mock.emitControl(.reconnecting)
        await mock.emitControl(.ready)
        try await waitUntil { let ca = await a.count; let cb = await b.count; return ca >= 2 && cb >= 2 }
        let ca = await a.count; let cb = await b.count
        XCTAssertGreaterThanOrEqual(ca, 2); XCTAssertGreaterThanOrEqual(cb, 2)
    }

    /// D2：注销某订阅者后，仅它被移除；其它订阅者后续重连仍被触发。
    func test_removeResumeHandler_removesOnlyThatSubscriber() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        try await driveToReady(store: store, mock: mock)

        let keep = FireBox(); let drop = FireBox()
        _ = await store.addResumeHandler { await keep.bump() }
        let dropToken = await store.addResumeHandler { await drop.bump() }
        try await waitUntil { let k = await keep.count; let d = await drop.count; return k >= 1 && d >= 1 }
        let dropAfterFirst = await drop.count

        await store.removeResumeHandler(dropToken)
        await mock.emitControl(.reconnecting)
        await mock.emitControl(.ready)
        try await waitUntil { await keep.count >= 2 }
        let dropFinal = await drop.count
        XCTAssertEqual(dropFinal, dropAfterFirst, "已注销订阅者不应再被触发")
    }

    /// D2：连接已就绪且已首连恢复后，新订阅者补触发恰一次，既有订阅者不重复触发。
    func test_lateSubscriber_backfillsExactlyOnce() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        try await driveToReady(store: store, mock: mock)

        let early = FireBox()
        _ = await store.addResumeHandler { await early.bump() }
        try await waitUntil { await early.count >= 1 }
        let earlyAfterFirst = await early.count

        let late = FireBox()
        _ = await store.addResumeHandler { await late.bump() }
        try await waitUntil { await late.count >= 1 }
        let lateCount = await late.count
        let earlyFinal = await early.count
        XCTAssertEqual(lateCount, 1, "新订阅者应补触发恰一次")
        XCTAssertEqual(earlyFinal, earlyAfterFirst, "既有订阅者不应因新订阅者加入而重复触发")
    }

    func test_readyEpochListsRunningThreadsOnceAndSkipsVisibleThreadsInGlobalResume() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        let main = FireBox(); let side = FireBox()
        _ = await store.addResumeHandler(threadId: "main") { await main.bump() }
        _ = await store.addResumeHandler(threadId: "side") { await side.bump() }

        let responder = Task {
            var answered = Set<String>()
            for _ in 0..<500 {
                if Task.isCancelled { return }
                for frame in await mock.sent {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = object["id"] as? String,
                          let method = object["method"] as? String,
                          !answered.contains(id) else { continue }
                    answered.insert(id)
                    switch method {
                    case RPCMethod.initialize:
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
                    case RPCMethod.threadLoadedList:
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"data":["main","side","hidden"],"nextCursor":null}}"#)
                    case RPCMethod.threadResume:
                        let threadId = (object["params"] as? [String: Any])?["threadId"] as? String ?? ""
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"thread":{"id":"\#(threadId)","turns":[]}}}"#)
                    default:
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{}}"#)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        await store.connect(config: .stub)
        try await waitUntil {
            let sent = await mock.sent
            let mainCount = await main.count
            let sideCount = await side.count
            return mainCount == 1 && sideCount == 1
                && sent.contains { $0.contains(RPCMethod.threadResume) && $0.contains(#""threadId":"hidden""#) }
        }
        responder.cancel()

        let sent = await mock.sent
        XCTAssertEqual(sent.filter { $0.contains(RPCMethod.threadLoadedList) }.count, 1)
        XCTAssertFalse(sent.contains { $0.contains(RPCMethod.threadResume) && $0.contains(#""threadId":"main""#) })
        XCTAssertFalse(sent.contains { $0.contains(RPCMethod.threadResume) && $0.contains(#""threadId":"side""#) })
        XCTAssertEqual(sent.filter { $0.contains(RPCMethod.threadResume) && $0.contains(#""threadId":"hidden""#) }.count, 1)
    }

    /// D2 helper：经 ControlEmittingTransport 握手驱动 store 到 .ready（复用 feedInitializeResponse 模式，
    /// 该 transport 支持 emitControl 以驱动物理重连事件——与 testReconnectReadyControlTriggersResync 同机制）。
    private func driveToReady(store: ConnectionStore, mock: ControlEmittingTransport) async throws {
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
    }

    /// 轮询条件直到为真或超时。
    private func waitUntil(timeout: TimeInterval = 3,
                          _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }

    // H2: disconnect() 必须关闭底层 transport（否则 WSTransport.pumpTask + ws task 泄漏，
    // 断线后还自动重连一个 UI 已丢弃的连接并继续 yield）。
    func testDisconnectClosesTransport() async throws {
        let spy = CloseSpyTransport()
        let store = await ConnectionStore(transportFactory: { _ in spy })
        // 后台模拟服务端：对 initialize 回响应使握手到达 .ready。
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await spy.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await spy.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        let before = await spy.closeCount
        XCTAssertEqual(before, 0, "断开前不应已关闭 transport")
        await store.disconnect()
        let after = await spy.closeCount
        XCTAssertGreaterThanOrEqual(after, 1, "disconnect() 必须关闭底层 transport")
    }

    // H1 接线：物理重连信号（.reconnecting）到达时，ConnectionStore 应让 rpc 失败在途请求，
    // 使断线瞬间挂起的请求抛错而非永久挂起。
    func testReconnectingControlFailsInflightRequest() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in ctrl })
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await ctrl.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await ctrl.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        let client = await store.rpc!
        let failed = FailBox()
        Task {
            do { _ = try await client.send(method: "thread/list", params: nil) }
            catch { await failed.mark() }
        }
        try await waitUntil {
            let s = await ctrl.sent
            return s.contains { $0.contains("thread/list") }
        }
        await ctrl.emitControl(.reconnecting)
        try await waitUntil { await failed.value }
        let didFail = await failed.value
        XCTAssertTrue(didFail, "重连信号到达后在途请求应失败，不应永久挂起")
    }

    /// 4.2 resync：物理重连成功（control 发 .ready）应经 resumeHandler 触发一次会话恢复（resync）。
    /// 首连已触发一次；模拟重连再发 .ready 后，handler 应被再触发一次（复用现有 resume 机制）。
    func testReconnectReadyControlTriggersResync() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in ctrl })
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await ctrl.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await ctrl.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        let fired = FireBox()
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        await store.setResumeHandler { await fired.bump() }
        // 首连恢复触发一次。
        try await waitUntil { await fired.count >= 1 }

        // 模拟物理重连成功：control 发 .ready → 再触发一次 resync。
        await ctrl.emitControl(.ready)
        try await waitUntil { await fired.count >= 2 }
        let count = await fired.count
        XCTAssertGreaterThanOrEqual(count, 2, "物理重连 .ready 应再触发一次 resync，实际 \(count)")
    }

    func testResumeHandlerAddedWhileReconnectingWaitsForReady() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in ctrl })
        await feedInitializeResponse(ctrl)
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }

        await ctrl.emitControl(.reconnecting)
        try await waitUntil { await store.phase == .reconnecting }
        let fired = FireBox()
        _ = await store.addResumeHandler { await fired.bump() }
        try await Task.sleep(for: .milliseconds(100))
        let countWhileReconnecting = await fired.count
        XCTAssertEqual(countWhileReconnecting, 0)

        await ctrl.emitControl(.ready)
        try await waitUntil { await fired.count == 1 }
    }

    func testInitialConnectTimeoutIsRetiredAfterReady() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in ctrl },
            connectTimeoutNanos: 120_000_000
        )
        await feedInitializeResponse(ctrl)
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }

        await ctrl.emitControl(.reconnecting)
        try await waitUntil { await store.phase == .reconnecting }
        try await Task.sleep(for: .milliseconds(180))

        let phaseAfterInitialDeadline = await store.phase
        XCTAssertEqual(phaseAfterInitialDeadline, .reconnecting,
                       "首连成功后，旧 timeout 不得把后续物理重连误判为首连失败")
    }

    /// 4.3 消费侧：重连退避耗尽（control 发 .connectionFailed）→ phase 落 .failed，
    /// 且**保留机器配置**（不要求重新配对，needsRePairing 保持 false），供用户手动重连。
    func testConnectionFailedControlKeepsConfigForManualRetry() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in ctrl })
        await feedInitializeResponse(ctrl)
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }

        await ctrl.emitControl(.connectionFailed)
        try await waitUntil {
            if case .failed = await store.phase { return true } else { return false }
        }
        // 连接失败 ≠ 信任撤销：不引导重新配对。
        let needs = await store.needsRePairing
        XCTAssertFalse(needs, "连接失败应保留机器配置、不要求重新配对")
    }

    /// 4.4 消费侧：信任被撤销（control 发 .trustRevoked）→ phase 落 .failed，
    /// 且置位 needsRePairing 引导 UI 回配对入口。
    func testTrustRevokedControlRequestsRePairing() async throws {
        let ctrl = ControlEmittingTransport()
        let store = await ConnectionStore(transportFactory: { _ in ctrl })
        await feedInitializeResponse(ctrl)
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }

        await ctrl.emitControl(.trustRevoked)
        try await waitUntil { await store.needsRePairing }
        let needs = await store.needsRePairing
        XCTAssertTrue(needs, "信任撤销应置位 needsRePairing 引导重新配对")
        if case .failed = await store.phase {} else { XCTFail("信任撤销应落 .failed，实际 \(await store.phase)") }
    }

    /// #2 冷启动首连即遇 trustRevoked：iPad 持 stableSessionId 冷启动做受信任复连，
    /// 开发机在线且已撤销该 iPad → 首连握手第一帧回 RejectHello。此时 observeControl 尚未订阅
    /// （只在 .ready 后订阅），故 .trustRevoked 控制事件无人消费；必须靠 awaitHandshake 冒泡的
    /// **可判别错误类型**让 connect 的 catch 置位 needsRePairing，否则用户被撤销后无重新配对出路。
    /// 断言：首连 RejectHello → connect 后 needsRePairing==true 且 phase 是撤销引导文案。
    func testFirstConnectRejectHelloRequestsRePairing() async throws {
        let devIdentity = Curve25519.Signing.PrivateKey()
        let pairing = PairingPayload(
            relayURL: "wss://relay.test", sessionId: "sess-cold",
            devIdentityPubB64: devIdentity.publicKey.rawRepresentation.base64EncodedString(),
            pairingCode: "cold-code", expiresAt: 9_999_999_999)
        // 首连（isTrustedReconnect=true）通道：对首帧 ClientHello 即回 RejectHello(trustRevoked)。
        let transport = RelayTransport(
            channelFactory: {
                LoopbackRelayWSChannel { text in
                    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(text.utf8))
                    let rej = try Handshake.makeRejectHello(clientHello: hello, reason: .trustRevoked,
                                                            devIdentity: devIdentity)
                    return String(decoding: try JSONEncoder().encode(rej), as: UTF8.self)
                }
            },
            pairing: pairing,
            ipadIdentity: Curve25519.Signing.PrivateKey(),
            ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "machine-cold",
            isTrustedReconnect: true,
            stableSessionStore: InMemoryStableSessionStore())
        let store = await ConnectionStore(transportFactory: { _ in transport })

        await store.connect(config: .stub)

        try await waitUntil { await store.needsRePairing }
        let needs = await store.needsRePairing
        XCTAssertTrue(needs, "首连收 RejectHello 应置位 needsRePairing 引导重新配对")
        if case .failed(let msg) = await store.phase {
            XCTAssertTrue(msg.contains("重新配对"), "phase 应为撤销引导文案，实际 \(msg)")
        } else {
            XCTFail("首连信任被拒应落 .failed，实际 \(await store.phase)")
        }
    }

    /// 4.1 心跳判死：注入恒 miss（probe 恒 false）的心跳，连续错过 missThreshold 次后
    /// 应经 onUnhealthy → transport.triggerReconnect() 触发一次有界重连。
    func test_heartbeatDeath_triggersReconnect() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .milliseconds(1), missThreshold: 2),
                                 probe: { false }, onUnhealthy: cb.run,
                                 sleep: { _ in await Task.yield() }) })
        await store.setTabActive(true)
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        try await waitUntil { await mock.triggerReconnectCount >= 1 }
        let count = await mock.triggerReconnectCount
        XCTAssertGreaterThanOrEqual(count, 1, "连续错过 2 次应触发一次有界重连")
    }

    /// peer-left 只是加速提示：第一次 miss 不判死，第二次连续 miss 才触发有界重连。
    func test_peerLeft_consecutiveProbeMisses_triggerReconnectAtThreshold() async throws {
        let mock = ControlEmittingTransport()
        let results = ResultScript([true, false, false])
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2,
                                               minimumAcceleratedProbeInterval: .zero),
                                 probe: { await results.next() }, onUnhealthy: cb.run,
                                 sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }) })
        await store.setTabActive(true)
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        try await waitUntil { await results.consumed == 1 }
        await mock.emitControl(.peerLeft)
        try await waitUntil { await results.consumed == 2 }
        let reconnectsAfterFirstMiss = await mock.triggerReconnectCount
        XCTAssertEqual(reconnectsAfterFirstMiss, 0, "第一次加速 miss 不得判死")
        await mock.emitControl(.peerLeft)
        try await waitUntil { await mock.triggerReconnectCount >= 1 }
        let count = await mock.triggerReconnectCount
        XCTAssertEqual(count, 1, "连续第二次 miss 才触发一次有界重连")
    }

    /// 4.1 防降级红线：peer-left 是提示非判决。健康时（探针恒 hit）收到伪造 peer-left
    /// 不得改 phase、不得断开、不得重连——判死权只在端到端心跳。
    func test_peerLeft_probeHit_ignored_staysReady() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .milliseconds(1), missThreshold: 2),
                                 probe: { true }, onUnhealthy: cb.run,
                                 sleep: { _ in await Task.yield() }) })
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        await mock.emitControl(.peerLeft)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await mock.triggerReconnectCount
        XCTAssertEqual(count, 0, "健康时收到伪造 peer-left 不得判死")
        if case .ready = await store.phase {} else { XCTFail("应保持 .ready，实际 \(await store.phase)") }
    }

    /// 后台回一条 initialize 响应，使握手到达 .ready（复用于多测试）。
    private func feedInitializeResponse(_ ctrl: ControlEmittingTransport) async {
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await ctrl.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await ctrl.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
    }
}

/// 记录 close() 调用次数的 transport（用于断言 disconnect 关闭底层连接）。
actor CloseSpyTransport: MessageTransport {
    private(set) var sent: [String] = []
    private(set) var closeCount = 0
    private var cont: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let stream: AsyncThrowingStream<String, Error>
    init() {
        var c: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
    }
    func send(_ text: String) async throws { sent.append(text) }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { stream }
    func close() async { closeCount += 1; cont?.finish(); cont = nil }
    func feed(_ json: String) { cont?.yield(json) }
}

/// 可发控制事件的 transport：用于驱动 ConnectionStore 的 .reconnecting → failInflight 接线测试。
actor ControlEmittingTransport: MessageTransport {
    private(set) var sent: [String] = []
    private var inCont: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let inStream: AsyncThrowingStream<String, Error>
    private var ctlCont: AsyncStream<TransportControlEvent>.Continuation?
    private nonisolated let ctlStream: AsyncStream<TransportControlEvent>
    init() {
        var ic: AsyncThrowingStream<String, Error>.Continuation!
        inStream = AsyncThrowingStream(bufferingPolicy: .unbounded) { ic = $0 }
        inCont = ic
        var cc: AsyncStream<TransportControlEvent>.Continuation!
        ctlStream = AsyncStream(bufferingPolicy: .unbounded) { cc = $0 }
        ctlCont = cc
    }
    private(set) var triggerReconnectCount = 0
    func send(_ text: String) async throws { sent.append(text) }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { inStream }
    nonisolated func control() -> AsyncStream<TransportControlEvent> { ctlStream }
    func close() async { inCont?.finish(); inCont = nil; ctlCont?.finish(); ctlCont = nil }
    func feed(_ json: String) { inCont?.yield(json) }
    func emitControl(_ ev: TransportControlEvent) { ctlCont?.yield(ev) }
    func triggerReconnect() async { triggerReconnectCount += 1 }
}

/// 记录在途请求是否失败。
actor FailBox {
    private(set) var value = false
    func mark() { value = true }
}

/// 记录 transportFactory 是否被调用（actor 保证跨任务并发安全）。
actor CallBox {
    private(set) var value = false
    func mark() { value = true }
}

/// 记录 resumeHandler 被触发的次数（actor 保证跨任务并发安全）。
actor FireBox {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// 按序返回预置 mock 的工厂（用于「首连取消 → 回前台重试」多次 connect 各拿不同 transport）。
/// 第 N 次 next() 返回第 N 个 mock，用尽后复用最后一个（防越界）。
actor MockSequenceFactory {
    private let mocks: [MockTransport]
    private var index = 0
    init(mocks: [MockTransport]) { self.mocks = mocks }
    func next() -> MockTransport {
        let m = mocks[min(index, mocks.count - 1)]
        index += 1
        return m
    }
}
