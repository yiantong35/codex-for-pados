import XCTest
@testable import CodexRemote

/// MockTransport 的可控扩展替身：额外暴露 control() 控制信号流与 emitControl(_:)，
/// 供 ConnectionStore 控制信号订阅（reconnecting/ready/snapshotNeeded）测试驱动。
actor ControllableMockTransport: MessageTransport {
    private(set) var sent: [String] = []
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>
    private var controlContinuation: AsyncStream<TransportControlEvent>.Continuation?
    private nonisolated let controlStream: AsyncStream<TransportControlEvent>

    init() {
        var ic: AsyncThrowingStream<String, Error>.Continuation!
        incomingStream = AsyncThrowingStream(bufferingPolicy: .unbounded) { ic = $0 }
        incomingContinuation = ic
        var cc: AsyncStream<TransportControlEvent>.Continuation!
        controlStream = AsyncStream(bufferingPolicy: .unbounded) { cc = $0 }
        controlContinuation = cc
    }

    // MARK: MessageTransport
    func send(_ text: String) async throws { sent.append(text) }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { incomingStream }
    nonisolated func control() -> AsyncStream<TransportControlEvent> { controlStream }
    func close() async {
        incomingContinuation?.finish(); incomingContinuation = nil
        controlContinuation?.finish(); controlContinuation = nil
    }

    // MARK: 测试驱动
    func feed(_ json: String) { incomingContinuation?.yield(json) }
    func emitControl(_ ev: TransportControlEvent) { controlContinuation?.yield(ev) }
}

/// resume 回调探针：记录是否被触发。
actor ResumeSpy {
    private(set) var fired = false
    func fire() { fired = true }
}

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

    // snapshotNeeded 控制信号 → 调用注入的 resume 回调。
    func testSnapshotNeededTriggersResume() async throws {
        let mock = ControllableMockTransport()
        let resumed = ResumeSpy()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        await store.setResumeHandler { await resumed.fire() }
        // 先握手到 ready（InitializeResponse 路径）
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let s = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId!)","result":{"userAgent":"c","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        await store.connect(config: .stub)
        try await waitUntil { await store.phase == .ready }
        await mock.emitControl(.snapshotNeeded)
        try await waitUntil { await resumed.fired }
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
