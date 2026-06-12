import XCTest
@testable import CodexRemote

final class ConnectionStoreTests: XCTestCase {
    func testHandshakeReachesReady() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        // 服务端在收到 initialize 后回响应（轮询 sent 比固定 sleep 更稳）。
        Task {
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if await mock.sent.contains(where: { $0.contains("\"method\":\"initialize\"") }) { break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
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

    func testReconnectingPhaseVisibleOnDrop() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        Task {
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if await mock.sent.contains(where: { $0.contains("\"method\":\"initialize\"") }) { break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"c","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        await mock.close()                     // 模拟断线
        try await waitUntil { await store.phase == .reconnecting }   // remote-connection: 重连中可见
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
