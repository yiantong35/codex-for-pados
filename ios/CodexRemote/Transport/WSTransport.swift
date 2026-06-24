import Foundation

/// ws 物理通道抽象：便于注入测试替身（生产用 URLSessionWebSocketTask 包装）。
protocol WebSocketChannel: Sendable {
    func send(text: String) async throws
    func receive() -> AsyncThrowingStream<String, Error>
    func close() async
}

/// 生产 ws 通道：URLSessionWebSocketTask 包装，把 text 帧桥成 AsyncThrowingStream。
final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    /// 建连所用的 URLRequest（供测试核对 Authorization header；token 不进 URL query）。
    let requestForTesting: URLRequest

    init(url: URL, bearerToken: String) {
        // token 走 ws 握手的 Authorization: Bearer header（官方 --ws-auth capability-token），
        // 不进 URL query，避免日志/历史泄漏。
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        self.requestForTesting = req
        self.task = URLSession.shared.webSocketTask(with: req)
        var c: AsyncThrowingStream<String, Error>.Continuation!
        self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        self.continuation = c
        task.resume()
        pump()
    }

    private func pump() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.continuation.finish(throwing: err)
            case .success(let msg):
                if case .string(let s) = msg { self.continuation.yield(s) }
                self.pump()   // 继续收下一帧
            }
        }
    }

    func send(text: String) async throws { try await task.send(.string(text)) }
    func receive() -> AsyncThrowingStream<String, Error> { stream }
    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}

/// WSTransport：在 MessageTransport seam 上实现官方 ws app-server 传输。
/// 直收发裸 JSON-RPC（一条消息 = 一个 ws text frame），不包/不解 envelope、不跟踪 seq。
/// 物理断开内部自动重连；重连完成只发 .ready（会话恢复由上层经 thread/loaded/list +
/// thread/resume rejoin 完成，设计 D1/D3）。
actor WSTransport: MessageTransport {
    private let connect: @Sendable (URL) -> WebSocketChannel
    private let url: URL
    private let reconnectDelay: TimeInterval
    private var channel: WebSocketChannel?
    private var pumpTask: Task<Void, Never>?
    private var reconnecting = false

    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>
    private var controlContinuation: AsyncStream<TransportControlEvent>.Continuation?
    private nonisolated let controlStream: AsyncStream<TransportControlEvent>

    /// 生产用：URL 为官方 ws endpoint，token 经 Authorization: Bearer header 传递（不进 URL query）。
    /// 测试用：注入 connect 替身，url/token 可为占位。
    init(url: URL = URL(string: "ws://placeholder")!,
         bearerToken: String = "",
         reconnectDelay: TimeInterval = 1.0,
         connect: (@Sendable (URL) -> WebSocketChannel)? = nil) {
        self.url = url
        self.reconnectDelay = reconnectDelay
        self.connect = connect ?? { URLSessionWebSocketChannel(url: $0, bearerToken: bearerToken) }
        var ic: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream(bufferingPolicy: .unbounded) { ic = $0 }
        self.incomingContinuation = ic
        var cc: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream(bufferingPolicy: .unbounded) { cc = $0 }
        self.controlContinuation = cc
    }

    func start() {
        guard channel == nil else { return }
        openChannelAndPump()
    }

    private func openChannelAndPump() {
        let ch = connect(url)
        channel = ch
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in ch.receive() {
                    await self.handleFrame(frame)
                }
                await self.handleChannelDropped()
            } catch {
                await self.handleChannelDropped()
            }
        }
    }

    /// 物理 ws 断开：保持逻辑 incoming() 流不结束，内部退避后重连。
    /// 去 seq 后不再补发 resync；重连完成只发 .ready，会话恢复由上层经
    /// thread/loaded/list + thread/resume(rejoin) 完成（设计 D3）。
    private func handleChannelDropped() async {
        guard !reconnecting else { return }
        reconnecting = true
        controlContinuation?.yield(.reconnecting)
        await channel?.close()
        channel = nil
        try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
        openChannelAndPump()
        reconnecting = false
        controlContinuation?.yield(.ready)
    }

    private func handleFrame(_ frame: String) {
        // 直接把整帧裸 JSON-RPC 文本交给 incoming()，不解 envelope、不跟踪 seq。
        incomingContinuation?.yield(frame)
    }

    // MARK: MessageTransport
    func send(_ text: String) async throws {
        // 重连窗口内 channel 为 nil：抛 .notConnected 让调用方（JSONRPCClient）
        // failPending 而非静默丢弃导致请求永久挂起。
        guard let channel else { throw TransportError.notConnected }
        // 直发裸 JSON-RPC 文本，一条消息一帧（帧边界不变量），不再包 envelope。
        try await channel.send(text: text)
    }

    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { incomingStream }

    nonisolated func control() -> AsyncStream<TransportControlEvent> { controlStream }

    func close() async {
        pumpTask?.cancel()
        await channel?.close()
        channel = nil
        incomingContinuation?.finish()
        incomingContinuation = nil
        controlContinuation?.finish()
        controlContinuation = nil
    }
}
