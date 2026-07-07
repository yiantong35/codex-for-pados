import Foundation
import Citadel
import NIOCore
import os

/// ProxyChannel 定位期 instrument 日志。定位收敛后保留精简版（握手写出 / 握手完成 / 首个 inbound）。
private let pcLog = Logger(subsystem: "com.tangyujie.codexremote", category: "proxychannel")

/// SSH 字节通道上的 ws 握手 + 帧编解码传输实现，接共享 daemon control socket。
///
/// 通道上跑标准 ws：`start()` 先写 ws Upgrade 请求，read loop 第一阶段累积 stdout 到 `\r\n\r\n`
/// 用 `WSFrame.validateHandshake` 校验（含 101 + 正确 Accept），失败即 finishIncoming；握手成功后
/// 切帧模式——stdout 喂入 buffer，`WSFrame.decodeFrames` 切出完整 text 帧逐条 yield；`send` 用
/// `WSFrame.encodeTextFrame` 编一帧（掩码客户端帧）写出。维持「1 条 JSON-RPC = 1 个 ws text frame」。
///
/// ## withExec 长驻闭包架构（依据 Task 3 spike 结论）
/// Citadel 的 `withExec(_:perform:)` 在 perform 闭包退出后立即 close 通道，且 inbound/outbound
/// 句柄只在闭包作用域内有效（不能拿出去存）。因此本 actor 在 `start()` 中启动一个常驻 Task 跑
/// `withExec`，闭包内并发跑两条 loop：
///
/// - **read loop**：消费 `inbound`（TTYOutput），先累积 HTTP 响应头校验 ws 握手，握手成功后把
///   stdout 字节喂入 ws 帧解码器，每条完整 text 帧 yield 给 `incoming()` 的消费者；stderr 仅忽略。
/// - **write loop**：第一条先写握手请求，之后消费 `stdinStream`（AsyncStream<String>），把每条
///   text 用 `WSFrame.encodeTextFrame` 编成一帧写到 `outbound`（TTYStdinWriter）。
///
/// `send(_:)` 只是往 `stdinContinuation` yield 字符串——outbound 写句柄永远留在闭包内，绝不跨
/// actor 边界。`close()` 结束 stdin 流 → write loop 退出 → withExec 闭包返回 → Citadel close 通道。
///
/// ## Swift 6 严格并发处理
/// `Citadel.SSHClient` / `TTYStdinWriter` / `TTYOutput` 均未声明 Sendable（底层是 NIO Channel /
/// AsyncThrowingStream，实际可安全传递）。read loop 与 write loop 触碰**不同**句柄（inbound vs
/// outbound），不存在对同一句柄的并发访问。沿用 spike 中已验证可编译的模式（spike 用
/// `ResultBox: @unchecked Sendable` 把非 Sendable 值带出闭包），这里用 `UncheckedBox` 把各句柄
/// 装箱后交给并发子任务——每个句柄只被一条 loop 独占，竞争不可能发生。
actor ProxyChannel: MessageTransport {
    /// 把非 Sendable 句柄装箱以跨并发子任务传递。每个 box 只被一条 loop 独占访问。
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// stdin 队列：send 写入端，闭包内 write loop 消费端。
    private let stdinStream: AsyncStream<String>
    private let stdinContinuation: AsyncStream<String>.Continuation

    /// incoming JSON 帧流：read loop 写入端，incoming() 的调用方消费端。
    /// stream 值本身 Sendable 且 init 后不可变，故 nonisolated 暴露给 incoming() 满足非 async 协议要求。
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>

    /// client 装箱后由常驻 Task 独占；actor 本身不再触碰它，避免非 Sendable 跨边界。
    private let clientBox: UncheckedBox<Citadel.SSHClient>
    private let command: String

    private var execTask: Task<Void, Never>?
    private var didStart = false

    /// ws 握手完成信号状态机：read loop 校验通过 → done，失败/通道提前关闭 → failed。
    /// awaitHandshake() 在 pending 时挂起于 continuation，done/failed 时立即返回/抛出。
    private enum HandshakeState { case pending, done, failed(Error) }
    private var handshakeState: HandshakeState = .pending
    private var handshakeContinuation: CheckedContinuation<Void, Error>?

    init(client: Citadel.SSHClient, command: String) {
        self.clientBox = UncheckedBox(client)
        self.command = command

        var stdinCont: AsyncStream<String>.Continuation!
        self.stdinStream = AsyncStream<String>(bufferingPolicy: .unbounded) { stdinCont = $0 }
        self.stdinContinuation = stdinCont

        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    /// 启动长驻 exec 通道。幂等：重复调用无副作用。
    func start() {
        guard !didStart else { return }
        didStart = true

        let clientBox = self.clientBox
        let command = self.command
        let stdinStream = self.stdinStream
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { await self?.emit(line) }
        }
        let onFinish: @Sendable (Error?) -> Void = { [weak self] err in
            Task { await self?.finishIncoming(err) }
        }
        let onHandshake: @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
            Task {
                switch result {
                case .success: await self?.markHandshakeDone()
                case .failure(let e): await self?.markHandshakeFailed(e)
                }
            }
        }

        // 本次连接的 ws 握手请求 + 随机 key（read/write loop 共享：write 写请求、read 校验 Accept）。
        let handshake = WSFrame.handshakeRequest()
        let handshakeRequest = handshake.request
        let handshakeKey = handshake.key

        execTask = Task {
            do {
                try await clientBox.value.withExec(command) { inbound, outbound in
                    // 句柄装箱：各自被一条 loop 独占。
                    let inBox = UncheckedBox(inbound)
                    let outBox = UncheckedBox(outbound)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // write loop：先写 ws 握手请求，再把每条 text 编成 ws 帧写 outbound。
                        group.addTask {
                            let hsBytes = Array(handshakeRequest.utf8)
                            pcLog.notice("② 握手写出前: \(hsBytes.count) bytes")
                            try await outBox.value.write(ByteBuffer(bytes: hsBytes))
                            pcLog.notice("② 握手写出返回（writeAndFlush 已 resolve）")
                            for await text in stdinStream {
                                try await outBox.value.write(ByteBuffer(bytes: WSFrame.encodeTextFrame(text)))
                            }
                        }
                        // read loop：第一阶段累积 HTTP 头校验握手，成功后切 ws 帧解码逐条 yield。
                        group.addTask {
                            var headBuffer = Data()      // 握手阶段累积 HTTP 响应头
                            var frameBuffer = Data()     // 握手后累积 ws 帧字节
                            var handshakeDone = false
                            var loggedFirstChunk = false
                            for try await chunk in inBox.value {
                                if !loggedFirstChunk {
                                    loggedFirstChunk = true
                                    switch chunk {
                                    case .stdout(let b):
                                        let n = min(64, b.readableBytes)
                                        let head = b.getBytes(at: b.readerIndex, length: n) ?? []
                                        pcLog.notice("③ 首个 inbound=.stdout \(b.readableBytes) bytes, 前\(n): \(head.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
                                    case .stderr(let b):
                                        let n = min(64, b.readableBytes)
                                        let head = b.getBytes(at: b.readerIndex, length: n) ?? []
                                        pcLog.notice("③ 首个 inbound=.stderr \(b.readableBytes) bytes, 前\(n): \(String(decoding: head, as: UTF8.self), privacy: .public)")
                                    }
                                }
                                guard case .stdout(let buffer) = chunk else { continue }
                                guard let bytes = buffer.getBytes(at: buffer.readerIndex,
                                                                  length: buffer.readableBytes) else { continue }
                                if !handshakeDone {
                                    headBuffer.append(contentsOf: bytes)
                                    // 找头结束分隔 \r\n\r\n
                                    guard let sep = headBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                                        continue   // 头还没收全，继续累积
                                    }
                                    let headData = headBuffer[headBuffer.startIndex..<sep.lowerBound]
                                    let responseHead = String(decoding: headData, as: UTF8.self)
                                    guard WSFrame.validateHandshake(responseHead: responseHead, key: handshakeKey) else {
                                        let e = TransportError.handshakeFailed("ws 握手失败：\(responseHead)")
                                        onHandshake(.failure(e))
                                        throw e
                                    }
                                    handshakeDone = true
                                    pcLog.notice("① 握手校验通过 handshakeDone=true")
                                    onHandshake(.success(()))
                                    // 头结束分隔后剩余字节属第一批 ws 帧，保留进 frameBuffer。
                                    let rest = headBuffer[sep.upperBound..<headBuffer.endIndex]
                                    frameBuffer.append(contentsOf: rest)
                                } else {
                                    frameBuffer.append(contentsOf: bytes)
                                }
                                // 切出 0..n 条完整 text 帧逐条 yield（不完整帧留 frameBuffer）。
                                for line in WSFrame.decodeFrames(buffer: &frameBuffer) {
                                    if !line.isEmpty { onLine(line) }
                                }
                            }
                        }
                        // 任一 loop 结束（流关闭 / 抛错）即收束整个 group → 闭包返回 → 通道 close。
                        try await group.next()
                        group.cancelAll()
                    }
                }
                pcLog.notice("④ withExec 闭包正常返回（write loop 结束触发 close）")
                onFinish(nil)
            } catch {
                pcLog.error("④ exec 通道结束/抛错: \(String(describing: error), privacy: .public)")
                onFinish(error)
            }
        }
    }

    private func emit(_ line: String) {
        incomingContinuation?.yield(line)
    }

    /// 阻塞直到 ws 握手完成：done 立即返回、failed 抛错、pending 挂起于 continuation。
    func awaitHandshake() async throws {
        switch handshakeState {
        case .done: return
        case .failed(let e): throw e
        case .pending:
            try await withCheckedThrowingContinuation { cont in
                self.handshakeContinuation = cont
            }
        }
    }

    /// read loop 握手校验通过时调用：置 done 并唤醒等待者（幂等，仅首次 pending 生效）。
    private func markHandshakeDone() {
        guard case .pending = handshakeState else { return }
        handshakeState = .done
        handshakeContinuation?.resume()
        handshakeContinuation = nil
    }

    /// 握手失败 / 通道在握手前关闭时调用：置 failed 并让等待者抛出（幂等）。
    private func markHandshakeFailed(_ error: Error) {
        guard case .pending = handshakeState else { return }
        handshakeState = .failed(error)
        handshakeContinuation?.resume(throwing: error)
        handshakeContinuation = nil
    }

    private func finishIncoming(_ error: Error?) {
        if case .pending = handshakeState {
            markHandshakeFailed(TransportError.channelClosed(reason: error.map { "\($0)" } ?? "通道在握手完成前关闭"))
        }
        if let error {
            incomingContinuation?.finish(throwing: TransportError.channelClosed(reason: "\(error)"))
        } else {
            incomingContinuation?.finish()
        }
        incomingContinuation = nil
    }

    // MARK: MessageTransport

    func send(_ text: String) async throws {
        stdinContinuation.yield(text)
    }

    nonisolated func incoming() -> AsyncThrowingStream<String, Error> {
        incomingStream
    }

    func close() async {
        stdinContinuation.finish()   // write loop 退出 → withExec 闭包返回 → 通道 close
        if case .pending = handshakeState {
            markHandshakeFailed(TransportError.channelClosed(reason: "连接主动关闭"))
        }
        incomingContinuation?.finish()
        incomingContinuation = nil
        execTask?.cancel()
    }

    #if DEBUG
    /// 测试工厂：造一个不启动 exec 的实例，仅用于验证握手状态机（绝不调 start()）。
    static func makeForTesting() -> ProxyChannel {
        ProxyChannel(testingSentinel: ())
    }
    /// 测试专用 init：clientBox 内的 client 是无效指针占位，测试实例绝不触碰它、绝不 start()。
    private init(testingSentinel: Void) {
        self.clientBox = UncheckedBox(unsafeBitCast(0, to: Citadel.SSHClient.self))
        self.command = ""
        var stdinCont: AsyncStream<String>.Continuation!
        self.stdinStream = AsyncStream<String>(bufferingPolicy: .unbounded) { stdinCont = $0 }
        self.stdinContinuation = stdinCont
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }
    func markHandshakeDoneForTesting() { markHandshakeDone() }
    func markHandshakeFailedForTesting(_ e: Error) { markHandshakeFailed(e) }
    #endif
}
