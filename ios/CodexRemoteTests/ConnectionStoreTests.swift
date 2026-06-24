import XCTest
@testable import CodexRemote

final class ConnectionStoreTests: XCTestCase {
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

    // 收到自己 id 的 Already initialized(-32600) 也视为握手成功 → ready。
    func testAlreadyInitializedReachesReady() async throws {
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
        try await waitUntil { await store.phase == .ready }
    }

    /// 空 token 时 connect 不调 transportFactory，直接落 .failed。
    @MainActor
    func testEmptyTokenDoesNotConnect() async throws {
        let calledBox = CallBox()
        let store = ConnectionStore(transportFactory: { _ in
            await calledBox.mark()
            throw TransportError.notConnected
        })
        store.connect(config: .init(host: "h", port: 8900, token: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        let called = await calledBox.value
        XCTAssertFalse(called, "空 token 不应调用 transportFactory")
        if case .failed = store.phase {} else { XCTFail("空 token 应落 .failed，实际 \(store.phase)") }
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
