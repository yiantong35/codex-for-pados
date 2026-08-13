import XCTest
import os
@testable import CodexRemote

/// 可注入的假 ws task：脚本化 receive 结果与 send 行为，不触真网络。
/// 用 `OSAllocatedUnfairLock` 而非 `NSLock`：后者的 lock/unlock 在 Swift 6 async 上下文不可用。
private final class FakeWSTask: WebSocketTaskProtocol, @unchecked Sendable {
    enum Recv { case text(String), data(Data), fail(Error) }
    private let recvScript: [Recv]
    private let idx = OSAllocatedUnfairLock(initialState: 0)
    var sendShouldThrow = false
    private(set) var resumed = false
    private(set) var cancelled = false
    let sendCount = OSAllocatedUnfairLock(initialState: 0)

    init(recv: [Recv] = []) { self.recvScript = recv }

    func resume() { resumed = true }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sendCount.withLock { $0 += 1 }
        if sendShouldThrow { throw URLError(.notConnectedToInternet) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let r: Recv? = idx.withLock { i in
            guard i < recvScript.count else { return nil }
            defer { i += 1 }
            return recvScript[i]
        }
        guard let r else { throw URLError(.cancelled) } // 脚本耗尽 = 关闭
        switch r {
        case .text(let s): return .string(s)
        case .data(let d): return .data(d)
        case .fail(let e): throw e
        }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }
}

private final class BlockingWSTask: WebSocketTaskProtocol, @unchecked Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<URLSessionWebSocketTask.Message, Error>?>(initialState: nil)
    private let didCancel = OSAllocatedUnfairLock(initialState: false)

    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            let alreadyCancelled = didCancel.withLock { $0 }
            if alreadyCancelled { cont.resume(throwing: URLError(.cancelled)); return }
            continuation.withLock { $0 = cont }
        }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didCancel.withLock { $0 = true }
        continuation.withLock { cont in
            cont?.resume(throwing: URLError(.cancelled))
            cont = nil
        }
    }
}

final class URLSessionRelayWSChannelTests: XCTestCase {

    /// 收 text 帧原样返回。
    func testReceiveTextReturnsString() async throws {
        let ch = URLSessionRelayWSChannel(task: FakeWSTask(recv: [.text("hi")]))
        let got = try await ch.receiveText()
        XCTAssertEqual(got, "hi")
    }

    /// 二进制帧被忽略，继续收下一条 text。
    func testReceiveSkipsBinaryFrame() async throws {
        let ch = URLSessionRelayWSChannel(task: FakeWSTask(recv: [.data(Data([0])), .text("after")]))
        let got = try await ch.receiveText()
        XCTAssertEqual(got, "after")
    }

    /// 连接关闭/取消 → receiveText 返回 nil（供 read loop 收束、供握手期判定连接关闭）。
    func testReceiveReturnsNilOnClose() async throws {
        let ch = URLSessionRelayWSChannel(task: FakeWSTask(recv: [.fail(URLError(.cancelled))]))
        let got = try await ch.receiveText()
        XCTAssertNil(got)
    }

    /// 不可达时 send 抛明确 TransportError（供握手 ClientHello 发送失败落 .failed）。
    func testSendThrowsTransportErrorWhenUnreachable() async {
        let task = FakeWSTask()
        task.sendShouldThrow = true
        let ch = URLSessionRelayWSChannel(task: task)
        do {
            try await ch.sendText("x")
            XCTFail("应抛错")
        } catch {
            guard case TransportError.channelClosed = error else {
                return XCTFail("应为 TransportError.channelClosed，实为 \(error)")
            }
        }
    }

    /// 通道已关闭后 sendText 前置守卫：直接抛 channelClosed，不再调用底层 task.send。
    func testSendAfterCloseThrowsWithoutCallingSend() async {
        let task = FakeWSTask()
        let ch = URLSessionRelayWSChannel(task: task)
        await ch.close()
        do {
            try await ch.sendText("x")
            XCTFail("关闭后应抛错")
        } catch {
            guard case TransportError.channelClosed = error else {
                return XCTFail("应为 TransportError.channelClosed，实为 \(error)")
            }
        }
        XCTAssertEqual(task.sendCount.withLock { $0 }, 0, "关闭后不得再触达底层 task.send")
    }

    func testCloseReleasesBlockedReceive() async throws {
        let ch = URLSessionRelayWSChannel(task: BlockingWSTask())
        let receive = Task { try await ch.receiveText() }
        await Task.yield()
        await ch.close()
        let result = try await receive.value
        XCTAssertNil(result)
    }
}
