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

    init(recv: [Recv] = []) { self.recvScript = recv }

    func resume() { resumed = true }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
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
}
