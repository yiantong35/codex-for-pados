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
/// ## 握手编排
/// 两条构造路径：
/// - `init(session:ws:)`：注入一个已建立的 SecureSession（测试/集成加解密数据流），握手视为 `.done`。
/// - `init(ws:pairing:ipadIdentity:ipadEphemeral:tofu:tofuMachineKey:)`：真握手路径。`awaitHandshake()`
///   驱动 `performHandshake()` 在 ws 上同步跑完 iPad 侧握手（`makeClientHello` → 收 ServerHello →
///   `verifyServerHelloAndMakeClientAuth` → TOFU 比对/首信 → 发 ClientAuth → `finishClient` 建
///   SecureSession），**先握手后启 read loop**（握手期用手动 sendText/receiveText，避免 read loop
///   抢走 ServerHello）。TOFU 在验开发机签名后、发 ClientAuth 前比对，身份变更立即拒绝。
///   任一步失败 → `markHandshakeFailed` + `ws.close()`，`awaitHandshake()` 抛错，绝不静默挂起。
///   （旧 `init(ws:)` 占位仍保留，供尚未接手真 ws 连接的工厂 `LiveTransport.makeRelayTransport` 构造。）
actor RelayTransport: MessageTransport {

    /// 已建立的加密会话（iPad 角色）。注入构造路径直接给定；真握手路径由 `performHandshake` 建立后回填。
    private var session: SecureSession?
    /// 底层 ws 通道（可注入）。
    private let ws: RelayWSChannel

    /// incoming 明文帧流：read loop 写入端，`incoming()` 调用方消费端。
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>

    /// read loop 常驻 Task。幂等启动。
    private var readTask: Task<Void, Never>?
    private var didStartRead = false

    /// 握手状态机：注入 SecureSession 路径直接 `.done`；真握手路径由 performHandshake 推进。
    private enum HandshakeState { case pending, done, failed(Error) }
    private var handshakeState: HandshakeState
    private var handshakeContinuation: CheckedContinuation<Void, Error>?

    /// 真握手所需注入项（仅真握手构造路径给定；注入 SecureSession 路径为 nil）。
    private struct HandshakeInputs {
        let pairing: PairingPayload
        let ipadIdentity: Curve25519.Signing.PrivateKey
        let ipadEphemeral: Curve25519.KeyAgreement.PrivateKey
        let tofu: TOFUStoring
        let tofuMachineKey: String
    }
    private let handshakeInputs: HandshakeInputs?
    /// 握手编排幂等启动守卫。
    private var didStartHandshake = false

    /// 注入构造路径：给定一个已建立的 SecureSession（测试/集成用）。握手视为已完成。
    init(session: SecureSession, ws: RelayWSChannel) {
        self.session = session
        self.ws = ws
        self.handshakeState = .done
        self.handshakeInputs = nil
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    /// 占位构造路径：仅给定 ws、无握手输入。真 ws 连接与握手编排尚未接入的工厂
    /// （`LiveTransport.makeRelayTransport`）用它构造实例；`awaitHandshake` 会因缺输入落 `.failed`。
    /// Task 5 接入真 ws 后由真握手构造取代此路径。
    init(ws: RelayWSChannel) {
        self.session = nil
        self.ws = ws
        self.handshakeState = .pending
        self.handshakeInputs = nil
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    /// 真握手构造路径：注入配对载荷 + iPad E2E 密钥 + TOFU，`awaitHandshake()` 触发 `performHandshake()`
    /// 编排 4 消息握手建 SecureSession。
    init(ws: RelayWSChannel,
         pairing: PairingPayload,
         ipadIdentity: Curve25519.Signing.PrivateKey,
         ipadEphemeral: Curve25519.KeyAgreement.PrivateKey,
         tofu: TOFUStoring,
         tofuMachineKey: String) {
        self.session = nil
        self.ws = ws
        self.handshakeState = .pending
        self.handshakeInputs = HandshakeInputs(
            pairing: pairing, ipadIdentity: ipadIdentity, ipadEphemeral: ipadEphemeral,
            tofu: tofu, tofuMachineKey: tofuMachineKey)
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
    }

    // MARK: read loop

    /// 启动常驻 read loop：持续从 ws 收密文帧 → open → yield 明文。幂等。
    /// **先握手后收 loop**：仅当握手 `.done` 才真正启动，避免 read loop 在握手期抢走 ServerHello
    /// （`JSONRPCClient` 的 pump 会先于 `awaitHandshake` 调 `incoming()` 触发本方法）。
    private func startReadLoopIfNeeded() {
        guard !didStartRead else { return }
        guard case .done = handshakeState else { return }
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

    // MARK: 真握手编排

    /// 幂等启动握手编排：`awaitHandshake` 首次进入 `.pending` 时调用。
    private func startHandshakeIfNeeded() {
        guard !didStartHandshake else { return }
        didStartHandshake = true
        Task { [weak self] in await self?.performHandshake() }
    }

    /// iPad 侧 4 消息握手编排（同步跑完，成功才启 read loop）：
    /// makeClientHello → 发 / 收 ServerHello → verifyServerHelloAndMakeClientAuth →
    /// TOFU 比对/首信（发 ClientAuth 前）→ 发 ClientAuth → finishClient 建 SecureSession。
    /// 不等第 4 条 SecureReady：finishClient 本地派生前会重验 devSignature，安全。
    private func performHandshake() async {
        guard let inputs = handshakeInputs else {
            markHandshakeFailed(TransportError.notConnected); return
        }
        do {
            let p = inputs.pairing
            guard let devIdentityPub = Data(base64Encoded: p.devIdentityPubB64) else {
                throw TransportError.proxyFailed("配对载荷开发机公钥非法")
            }
            let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let ipadDeviceId = inputs.ipadIdentity.publicKey.rawRepresentation.base64EncodedString()

            let hello = Handshake.makeClientHello(
                sessionId: p.sessionId, ipadDeviceId: ipadDeviceId,
                ipadIdentityPub: inputs.ipadIdentity.publicKey.rawRepresentation,
                ipadEphemeralPub: inputs.ipadEphemeral.publicKey.rawRepresentation,
                clientNonce: clientNonce, pairingCode: p.pairingCode)
            try await ws.sendText(String(decoding: try JSONEncoder().encode(hello), as: UTF8.self))

            guard let shText = try await ws.receiveText() else {
                throw TransportError.channelClosed(reason: "握手中连接关闭（等 ServerHello）")
            }
            let serverHello = try JSONDecoder().decode(ServerHello.self, from: Data(shText.utf8))

            let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
                clientHello: hello, serverHello: serverHello,
                devIdentityPub: devIdentityPub, ipadIdentity: inputs.ipadIdentity)

            // TOFU：验开发机签名通过后、发 ClientAuth 之前比对/首信（身份变更即拒，
            // 绝不向被替换身份的机器出示一次性口令）。用配对载荷 pub 作信任锚——它才是带外
            // 获得的锚（验签也用它、transcript 覆盖 serverHello.devIdentityPub，验签通过后二者必然相等）。
            try inputs.tofu.verifyOrTrust(machineKey: inputs.tofuMachineKey,
                                          presentedPub: devIdentityPub)

            try await ws.sendText(String(decoding: try JSONEncoder().encode(clientAuth), as: UTF8.self))

            let secure = try Handshake.finishClient(
                clientHello: hello, serverHello: serverHello,
                ipadEphemeral: inputs.ipadEphemeral, devIdentityPub: devIdentityPub)

            self.session = secure
            markHandshakeDone()
            startReadLoopIfNeeded()
        } catch {
            rtLog.error("握手失败: \(String(describing: error), privacy: .public)")
            // 先落 .failed 保留真实握手错误类型给 awaitHandshake，再收束 incoming 流：
            // 握手失败时 read loop 从未启动（被 startReadLoopIfNeeded 的 .done 守卫挡住），
            // 故此处是唯一收束路径。不收束会让 JSONRPCClient pump（握手前就 for-await incoming）永久挂起。
            markHandshakeFailed(error)
            incomingContinuation?.finish(throwing: TransportError.channelClosed(reason: "\(error)"))
            incomingContinuation = nil
            await ws.close()
        }
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
            // 先排队握手编排再挂起：actor 在本函数挂起前不会调度排入的 Task，
            // 故 continuation 一定在 markHandshakeDone/Failed 前设好，不会丢通知。
            startHandshakeIfNeeded()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
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
