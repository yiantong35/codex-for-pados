import Foundation
import Crypto
import RelayProtocol
import os

/// RelayTransport 精简 instrument 日志（三点：send 加密 / incoming 解密 / 异常退出）。
private let rtLog = Logger(subsystem: "com.tangyujie.codexremote", category: "relaytransport")

/// 可注入的 ws 通道抽象。生产实现包 `URLSessionWebSocketTask`，测试注入内存 mock。
///
/// 把「真网络 ws 收发」与「E2E 加解密数据流」解耦：RelayTransport 只面向本抽象，
/// 加解密逻辑因此可脱离真网络单测。一条 text frame = 一条 SecureEnvelope JSON。
protocol RelayWSChannel: Sendable {
    /// 发送一条 text frame（内容是 SecureEnvelope 的 JSON）。
    func sendText(_ text: String) async throws
    /// 阻塞收下一条 text frame；连接关闭返回 nil。
    func receiveText() async throws -> String?
    func close() async
}

/// Relay 传输实现：与 `ProxyChannel` 同实现 `MessageTransport` seam，对上层（JSONRPCClient/
/// ConversationStore/UI）就是「又一个 transport」——上层零改。区别在于本 transport 内部做
/// **端到端加解密**：明文 JSON-RPC 帧 seal 成 `SecureEnvelope` 密文才出线，收到的密文 open
/// 回明文才 yield 给上层。中继服务器只见密文信封（header 明文仅供路由/防重放）。
///
/// ## 数据流
/// - `send(明文 text)` → `session.seal(utf8)` → `env.encoded()` → ws text frame 发出。
/// - `incoming()`：read loop 持续 `ws.receiveText()` → `SecureEnvelope(decoding:)` →
///   `session.open(env)` → yield String(明文)。
/// - `close()`：结束 read loop + 关 ws + 收束 incoming 流。
///
/// ## 握手编排（本 task 范围界定）
/// 本 task 聚焦「已建立 SecureSession 之上的加解密数据流」，故提供一个**注入 SecureSession**
/// 的构造路径（`init(session:ws:)`）供测试与集成复用。真 ws 网络连接 + iPad 侧 4 消息握手编排
/// （`Handshake.makeClientHello` / `verifyServerHelloAndMakeClientAuth` / `finishClient`，用配对
/// 载荷的 devIdentityPub 验开发机、pairingCode 生成 proof）留到 Task 13/真机集成，见 `connect(...)`
/// 的 TODO。
actor RelayTransport: MessageTransport {

    /// 已建立的加密会话（iPad 角色）。注入构造路径直接给定；真握手路径由 `connect` 建立后回填。
    private var session: SecureSession?
    /// 底层 ws 通道（可注入）。
    private let ws: RelayWSChannel

    /// incoming 明文帧流：read loop 写入端，`incoming()` 调用方消费端。
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>

    /// read loop 常驻 Task。幂等启动。
    private var readTask: Task<Void, Never>?
    private var didStartRead = false

    /// 握手状态机：注入 SecureSession 路径直接 `.done`；真握手路径由 connect 推进。
    private enum HandshakeState { case pending, done, failed(Error) }
    private var handshakeState: HandshakeState
    private var handshakeContinuation: CheckedContinuation<Void, Error>?

    /// 注入构造路径：给定一个已建立的 SecureSession（测试/集成用）。握手视为已完成。
    init(session: SecureSession, ws: RelayWSChannel) {
        self.session = session
        self.ws = ws
        self.handshakeState = .done
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    /// 真握手构造路径：仅给定 ws，SecureSession 由 `connect` 编排握手后建立。
    init(ws: RelayWSChannel) {
        self.session = nil
        self.ws = ws
        self.handshakeState = .pending
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    // MARK: read loop

    /// 启动常驻 read loop：持续从 ws 收密文帧 → open → yield 明文。幂等。
    private func startReadLoopIfNeeded() {
        guard !didStartRead else { return }
        didStartRead = true
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func runReadLoop() async {
        do {
            while true {
                guard let frame = try await ws.receiveText() else {
                    finishIncoming(nil)   // ws 正常关闭
                    return
                }
                guard let session else {
                    // 握手未完成前不该有业务帧；防御性丢弃。
                    continue
                }
                let env = try SecureEnvelope(decoding: Data(frame.utf8))
                let plaintext = try session.open(env)
                emit(String(decoding: plaintext, as: UTF8.self))
            }
        } catch {
            rtLog.error("read loop 退出/抛错: \(String(describing: error), privacy: .public)")
            finishIncoming(error)
        }
    }

    private func emit(_ line: String) {
        incomingContinuation?.yield(line)
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

    // MARK: 握手状态机

    private func markHandshakeDone() {
        guard case .pending = handshakeState else { return }
        handshakeState = .done
        handshakeContinuation?.resume()
        handshakeContinuation = nil
    }

    private func markHandshakeFailed(_ error: Error) {
        guard case .pending = handshakeState else { return }
        handshakeState = .failed(error)
        handshakeContinuation?.resume(throwing: error)
        handshakeContinuation = nil
    }

    // MARK: 真握手编排（留集成/真机）

    /// 真 ws 网络握手编排入口：连 ws + 跑 iPad 侧 4 消息握手建立 SecureSession，成功才 ready。
    ///
    /// TODO(Task 13/集成)：用 `pairing` 里的 relayURL 连真 ws；用 `devIdentityPubB64` 验开发机、
    /// `pairingCode` 经 `Handshake.pairingCodeProof` 生成 proof；跑
    /// `makeClientHello` → 发 ClientHello / 收 ServerHello →
    /// `verifyServerHelloAndMakeClientAuth` → 发 ClientAuth / 收 SecureReady →
    /// `finishClient` 得 SecureSession，回填 `self.session` 并 `markHandshakeDone()`。
    /// 本 task 只交付加解密数据流 + seam；真网络握手编排在此标记留集成。
    func connect(pairing: PairingPayload,
                 ipadIdentity: Curve25519.Signing.PrivateKey,
                 ipadEphemeral: Curve25519.KeyAgreement.PrivateKey) async throws {
        // TODO(Task 13/集成)：实现真握手编排（见方法文档）。
        throw TransportError.notConnected
    }

    // MARK: MessageTransport

    func send(_ text: String) async throws {
        guard let session else { throw TransportError.notConnected }
        let env = try session.seal(Data(text.utf8))
        let frame = String(decoding: try env.encoded(), as: UTF8.self)
        try await ws.sendText(frame)
    }

    nonisolated func incoming() -> AsyncThrowingStream<String, Error> {
        // 首次取流即启动 read loop（在 actor 上下文中幂等启动）。
        Task { await self.startReadLoopIfNeeded() }
        return incomingStream
    }

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

    func close() async {
        await ws.close()
        if case .pending = handshakeState {
            markHandshakeFailed(TransportError.channelClosed(reason: "连接主动关闭"))
        }
        incomingContinuation?.finish()
        incomingContinuation = nil
        readTask?.cancel()
    }
}
