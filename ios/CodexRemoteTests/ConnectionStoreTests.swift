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
