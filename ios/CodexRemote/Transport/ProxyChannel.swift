import Foundation
import Citadel
import NIOCore

/// 在 Citadel exec 通道的 stdio 上做**换行分隔 JSON 帧**收发的传输实现。
///
/// ## withExec 长驻闭包架构（依据 Task 3 spike 结论）
/// Citadel 的 `withExec(_:perform:)` 在 perform 闭包退出后立即 close 通道，且 inbound/outbound
/// 句柄只在闭包作用域内有效（不能拿出去存）。因此本 actor 在 `start()` 中启动一个常驻 Task 跑
/// `withExec`，闭包内并发跑两条 loop：
///
/// - **read loop**：消费 `inbound`（TTYOutput），把 stdout 字节按 `\n` 分帧，每条完整 JSON
///   行 yield 给 `incoming()` 的消费者；stderr 仅忽略。
/// - **write loop**：消费 `stdinStream`（AsyncStream<String>），把每条 text + "\n" 写到
///   `outbound`（TTYStdinWriter）。
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

        execTask = Task {
            do {
                try await clientBox.value.withExec(command) { inbound, outbound in
                    // 句柄装箱：各自被一条 loop 独占。
                    let inBox = UncheckedBox(inbound)
                    let outBox = UncheckedBox(outbound)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // write loop：消费 stdin 队列写 outbound。
                        group.addTask {
                            for await text in stdinStream {
                                let line = text.hasSuffix("\n") ? text : text + "\n"
                                try await outBox.value.write(ByteBuffer(string: line))
                            }
                        }
                        // read loop：按换行分帧逐条 yield。
                        group.addTask {
                            var pending = Data()
                            for try await chunk in inBox.value {
                                guard case .stdout(let buffer) = chunk else { continue }
                                if let bytes = buffer.getBytes(at: buffer.readerIndex,
                                                               length: buffer.readableBytes) {
                                    pending.append(contentsOf: bytes)
                                }
                                // 一次 chunk 可能含 0..n 条完整行，逐条切出（处理不完整行缓冲）。
                                while let nl = pending.firstIndex(of: 0x0A) {
                                    let lineData = pending[pending.startIndex..<nl]
                                    let line = String(decoding: lineData, as: UTF8.self)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    pending.removeSubrange(pending.startIndex...nl)
                                    if !line.isEmpty { onLine(line) }
                                }
                            }
                        }
                        // 任一 loop 结束（流关闭 / 抛错）即收束整个 group → 闭包返回 → 通道 close。
                        try await group.next()
                        group.cancelAll()
                    }
                }
                onFinish(nil)
            } catch {
                onFinish(error)
            }
        }
    }

    private func emit(_ line: String) {
        incomingContinuation?.yield(line)
    }

    private func finishIncoming(_ error: Error?) {
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
        incomingContinuation?.finish()
        incomingContinuation = nil
        execTask?.cancel()
    }
}
