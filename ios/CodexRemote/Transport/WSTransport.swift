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

    init(url: URL) {
        self.task = URLSession.shared.webSocketTask(with: url)
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

/// WSTransport：在 MessageTransport seam 上实现 daemon ws 传输。
/// 出向包 request envelope，入向解 event 取 payload（一行 JSON）交给 incoming()，跟踪 lastSeq。
/// 自动重连/resync/控制信号在后续任务加入（本任务仅单次连接收发）。
actor WSTransport: MessageTransport {
    private let connect: @Sendable (URL) -> WebSocketChannel
    private let url: URL
    private let reconnectDelay: TimeInterval
    private var channel: WebSocketChannel?
    private var lastSeq: UInt64 = 0
    private var pumpTask: Task<Void, Never>?
    private var reconnecting = false

    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>
    private var controlContinuation: AsyncStream<TransportControlEvent>.Continuation?
    private nonisolated let controlStream: AsyncStream<TransportControlEvent>

    /// 生产用：URL 已含 ?token=。测试用：注入 connect 替身，url 可为占位。
    init(url: URL = URL(string: "ws://placeholder")!,
         reconnectDelay: TimeInterval = 1.0,
         connect: @escaping @Sendable (URL) -> WebSocketChannel =
            { URLSessionWebSocketChannel(url: $0) }) {
        self.url = url
        self.reconnectDelay = reconnectDelay
        self.connect = connect
        var ic: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream(bufferingPolicy: .unbounded) { ic = $0 }
        self.incomingContinuation = ic
        var cc: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream(bufferingPolicy: .unbounded) { cc = $0 }
        self.controlContinuation = cc
    }

    /// 测试可见的 lastSeq。
    var lastSeqForTesting: UInt64 { lastSeq }

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

    /// 物理 ws 断开：保持逻辑 incoming() 流不结束，内部退避后重连并 resync。
    private func handleChannelDropped() async {
        guard !reconnecting else { return }
        reconnecting = true
        controlContinuation?.yield(.reconnecting)
        await channel?.close()
        channel = nil
        try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
        openChannelAndPump()
        // 重连后补发 resync(after=lastSeq)
        let resync = #"{"type":"resync","after":\#(lastSeq)}"#
        try? await channel?.send(text: resync)
        reconnecting = false
        controlContinuation?.yield(.ready)
    }

    private func handleFrame(_ frame: String) {
        guard let env = try? EnvelopeCodec.decode(line: frame) else { return }
        switch env {
        case .event(let seq, let payloadJSON):
            lastSeq = seq
            incomingContinuation?.yield(payloadJSON)
        case .snapshotNeeded:
            controlContinuation?.yield(.snapshotNeeded)
        case .resync:
            break   // iPad 不消费入向 resync
        }
    }

    // MARK: MessageTransport
    func send(_ text: String) async throws {
        let framed = try EnvelopeCodec.encodeRequest(payloadJSON: text)
        try await channel?.send(text: framed)
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
