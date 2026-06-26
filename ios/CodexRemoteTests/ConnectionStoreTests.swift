import XCTest
@testable import CodexRemote

final class ConnectionStoreTests: XCTestCase {
    /// connect() 现含「本机密钥已生成」前置校验（KeyManager.hasKey）。
    /// 走 mock transport 的握手/重连测试与密钥无关，故先确保 Keychain 里存在密钥，
    /// 让 .stub 连接能越过前置校验进入注入的 mock 工厂。
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { KeyManager().generateIfNeeded() }
    }

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

    /// 必填项缺失（host/user/sock 路径任一为空）时 connect 不调 transportFactory，直接落 .failed。
    @MainActor
    func testIncompleteConfigDoesNotConnect() async throws {
        let calledBox = CallBox()
        let store = ConnectionStore(transportFactory: { _ in
            await calledBox.mark()
            throw TransportError.notConnected
        })
        // sock 路径为空 → 前置校验拒绝，不应进入工厂。
        store.connect(config: .init(host: "h", user: "u", sshPort: 22, controlSockPath: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        let called = await calledBox.value
        XCTAssertFalse(called, "必填项缺失不应调用 transportFactory")
        if case .failed = store.phase {} else { XCTFail("必填项缺失应落 .failed，实际 \(store.phase)") }
    }

    // snapshotNeeded 控制信号已随去 envelope 移除（设计 D1）；重连后会话恢复改由
    // §5 经 thread/loaded/list + thread/resume 完成，相应测试归属 §5。

    /// §5 修正：首次连接成功（initialize 完成、phase=.ready）后也应触发一次 resumeHandler
    /// （= rejoinRunningThreads），以「连上自动订阅全部活跃 thread」对齐需求——
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
    func send(_ text: String) async throws { sent.append(text) }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { inStream }
    nonisolated func control() -> AsyncStream<TransportControlEvent> { ctlStream }
    func close() async { inCont?.finish(); inCont = nil; ctlCont?.finish(); ctlCont = nil }
    func feed(_ json: String) { inCont?.yield(json) }
    func emitControl(_ ev: TransportControlEvent) { ctlCont?.yield(ev) }
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
