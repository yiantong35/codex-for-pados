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

/// 收到 RejectHello（应用层拒绝，独有 `kind` tag）时抛出：与传输层失败区分。
/// 首连时冒泡为握手失败；重连时触发 `.trustRevoked` 终态且**不再重连**。
struct RejectHelloError: Error {
    let reason: RejectReason
}

/// 断线重连退避策略（可注入以便测试免真 sleep）。
/// 指数退避 + 硬上限 + 有限重试：`baseDelay * 2^attempt` 封顶 `maxDelay`，试满 `maxAttempts` 次进终态。
struct RelayReconnectPolicy: Sendable {
    let maxAttempts: Int
    let baseDelaySeconds: Double
    let maxDelaySeconds: Double
    /// 退避挂起（默认真 sleep；测试注入 no-op / 记录钩子）。
    let sleep: @Sendable (Double) async -> Void

    init(maxAttempts: Int = 6, baseDelaySeconds: Double = 1.0, maxDelaySeconds: Double = 30.0,
         sleep: @escaping @Sendable (Double) async -> Void = { s in
             try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
         }) {
        self.maxAttempts = maxAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.sleep = sleep
    }

    /// 第 `attempt`（0 起）次退避秒数：指数增长封顶 `maxDelaySeconds`。
    func delaySeconds(attempt: Int) -> Double {
        min(baseDelaySeconds * pow(2.0, Double(attempt)), maxDelaySeconds)
    }
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
/// - `init(session:ws:)`：注入一个已建立的 SecureSession（测试/集成加解密数据流），握手视为 `.done`，
///   无 channel factory 故不重连。
/// - `init(channelFactory:pairing:…)`：真握手 + 断线重连路径。`awaitHandshake()` 驱动
///   `performHandshake()` 调 `channelFactory()` 造通道并跑完 iPad 侧握手建 SecureSession。
///
/// ## 断线自动重连（三改造点）
/// 1. **ws 从注入常量 → channel factory**：`ws` 变可空的当前活跃通道，重连时调工厂造**新**通道并每轮
///    新生成 ephemeral（前向保密），身份复用。
/// 2. **incoming 跨重连存活**：read loop 检测 ws 断——**主动 close** → 终结流；**瞬断** → 不 finish，
///    转重连循环（`AsyncThrowingStream` 静态挂起，几乎零能耗），`.ready` 后继续 yield。
/// 3. **control 事件**：进重连发 `.reconnecting`；重连成功发 `.ready`；退避耗尽发 `.connectionFailed`
///    （终态）；收 RejectHello 发 `.trustRevoked`（终态，不再重连）。
/// 退避有硬上限（`RelayReconnectPolicy`）绝不无限重连；主动断 / 信任撤销为终态。
actor RelayTransport: MessageTransport {

    /// 已建立的加密会话（iPad 角色）。注入构造路径直接给定；真握手路径由 `performHandshakeOn` 建立后回填。
    private var session: SecureSession?
    /// 当前活跃 ws 通道。注入路径为固定通道；真握手路径首连/每次重连由工厂造新通道后回填。
    private var ws: RelayWSChannel?
    /// 造新通道的工厂（仅真握手路径给定；注入/占位路径为 nil → 不重连）。
    private let channelFactory: (@Sendable () async throws -> RelayWSChannel)?
    /// 主动 close 标志：read loop 见 ws 断时据此区分「主动关闭（终态）」与「瞬断（转重连）」。
    private var activeClose = false

    /// 前台/后台状态（能耗）：后台时重连循环挂起等待回前台，不持续造新连接烧电（4.5）。默认前台。
    private var isForeground = true
    /// 后台→前台的唤醒等待者（重连循环挂起点）。回前台 / close() 时 resume 以避免 continuation 泄漏。
    private var foregroundWaiter: CheckedContinuation<Void, Never>?

    /// incoming 明文帧流：read loop 写入端，`incoming()` 调用方消费端。跨重连存活（瞬断不 finish）。
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let incomingStream: AsyncThrowingStream<String, Error>

    /// 控制信号流：重连各阶段 yield（.reconnecting/.ready/.connectionFailed/.trustRevoked）。
    private var controlContinuation: AsyncStream<TransportControlEvent>.Continuation?
    private nonisolated let controlStream: AsyncStream<TransportControlEvent>

    /// read loop 常驻 Task。幂等启动 / 重连后重启。
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
        /// 每次握手新生成 iPad ephemeral（前向保密；重连亦新生成）。身份 `ipadIdentity` 则复用。
        let ephemeralProvider: @Sendable () -> Curve25519.KeyAgreement.PrivateKey
        let tofu: TOFUStoring
        let tofuMachineKey: String
        /// 受信任复连：iPad 身份已在 dev 信任列表内，发空 proof 免一次性 pairingCode（验签 + TOFU 不省）。
        let isTrustedReconnect: Bool
        /// 消费第 4 条 SecureReady 后持久化 dev 回传的 stableSessionId（撮合标签）。
        let stableSessionStore: StableSessionStoring
    }
    private let handshakeInputs: HandshakeInputs?
    /// 重连退避策略。
    private let reconnect: RelayReconnectPolicy
    /// 握手编排幂等启动守卫。
    private var didStartHandshake = false

    /// 注入构造路径：给定一个已建立的 SecureSession（测试/集成用）。握手视为已完成，无工厂故不重连。
    init(session: SecureSession, ws: RelayWSChannel) {
        self.session = session
        self.ws = ws
        self.channelFactory = nil
        self.handshakeState = .done
        self.handshakeInputs = nil
        self.reconnect = RelayReconnectPolicy()
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
        var ctlCont: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream<TransportControlEvent>(bufferingPolicy: .unbounded) { ctlCont = $0 }
        self.controlContinuation = ctlCont
    }

    /// 占位构造路径：仅给定 ws、无握手输入、无工厂。真 ws 连接与握手编排尚未接入的调用方用它构造；
    /// `awaitHandshake` 会因缺输入落 `.failed`。
    init(ws: RelayWSChannel) {
        self.session = nil
        self.ws = ws
        self.channelFactory = nil
        self.handshakeState = .pending
        self.handshakeInputs = nil
        self.reconnect = RelayReconnectPolicy()
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
        var ctlCont: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream<TransportControlEvent>(bufferingPolicy: .unbounded) { ctlCont = $0 }
        self.controlContinuation = ctlCont
    }

    /// 真握手 + 断线重连构造路径：注入 channel factory + 配对载荷 + iPad 身份 + ephemeral 工厂 + TOFU。
    /// `awaitHandshake()` 触发 `performHandshake()`：调 `channelFactory()` 造通道 → 编排 4 消息握手建
    /// SecureSession。read loop 检测瞬断即调工厂造新通道重握手（退避 + 上限，见 `reconnect`）。
    init(channelFactory: @escaping @Sendable () async throws -> RelayWSChannel,
         pairing: PairingPayload,
         ipadIdentity: Curve25519.Signing.PrivateKey,
         ephemeralProvider: @escaping @Sendable () -> Curve25519.KeyAgreement.PrivateKey,
         tofu: TOFUStoring,
         tofuMachineKey: String,
         isTrustedReconnect: Bool,
         stableSessionStore: StableSessionStoring,
         reconnect: RelayReconnectPolicy = RelayReconnectPolicy()) {
        self.session = nil
        self.ws = nil
        self.channelFactory = channelFactory
        self.handshakeState = .pending
        self.handshakeInputs = HandshakeInputs(
            pairing: pairing, ipadIdentity: ipadIdentity, ephemeralProvider: ephemeralProvider,
            tofu: tofu, tofuMachineKey: tofuMachineKey,
            isTrustedReconnect: isTrustedReconnect, stableSessionStore: stableSessionStore)
        self.reconnect = reconnect
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
        var ctlCont: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream<TransportControlEvent>(bufferingPolicy: .unbounded) { ctlCont = $0 }
        self.controlContinuation = ctlCont
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

    /// 重连成功后重启 read loop（旧 loop 已在进入重连时返回，故此处新建不会与之并存）。
    private func restartReadLoop() {
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func runReadLoop() async {
        do {
            while true {
                guard let ws else { finishIncoming(nil); return }
                guard let frame = try await ws.receiveText() else {
                    await handleDisconnect(nil)   // ws 关闭（可能瞬断，可能主动）
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
            await handleDisconnect(error)
        }
    }

    /// read loop 检测 ws 断后的分流：**主动 close** 或**无工厂**（注入路径）→ 终结 incoming；
    /// 否则**瞬断** → 不 finish incoming，转重连循环（incoming 静态挂起存活）。
    private func handleDisconnect(_ error: Error?) async {
        if activeClose || channelFactory == nil {
            finishIncoming(error)
            return
        }
        await reconnectLoop()
    }

    private func emit(_ line: String) {
        incomingContinuation?.yield(line)
    }

    private func emitControl(_ ev: TransportControlEvent) {
        controlContinuation?.yield(ev)
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

    /// 重连终态（连接失败 / 信任撤销）收束 incoming：直接以给定错误抛错终止（不二次包裹）。
    private func finishIncomingTerminal(_ error: Error) {
        incomingContinuation?.finish(throwing: error)
        incomingContinuation = nil
    }

    // MARK: 断线重连循环

    /// 瞬断后的重连循环：指数退避 + 硬上限 + 有限重试。
    /// - 每次尝试前发 `.reconnecting`、退避挂起；成功 → 回填 ws/重启 read loop → 发 `.ready` 返回。
    /// - 收 RejectHello → 发 `.trustRevoked` + 终结 incoming，**不再重连**（4.4）。
    /// - 试满 `maxAttempts` 仍失败 → 发 `.connectionFailed` + 终结 incoming（4.3 终态，绝不无限重连）。
    /// - 主动 close / 任务取消 → 静默退出（不发终态、不再造通道）。
    private func reconnectLoop() async {
        guard let factory = channelFactory else { finishIncoming(nil); return }
        var attempt = 0
        while attempt < reconnect.maxAttempts {
            if activeClose || Task.isCancelled { return }
            // 能耗：后台则挂起等待回前台，不在后台持续造新连接烧电（4.5）。
            await waitForForeground()
            if activeClose || Task.isCancelled { return }
            emitControl(.reconnecting)
            await reconnect.sleep(reconnect.delaySeconds(attempt: attempt))
            if activeClose || Task.isCancelled { return }
            do {
                let ch = try await factory()
                do {
                    try await performHandshakeOn(ch)
                } catch {
                    await ch.close()
                    throw error
                }
                // #1 竞态硬化：performHandshakeOn 的 await 期间 close() 可能已落地（置 activeClose、
                // cancel readTask、收束流）而握手仍成功返回。此时若原子执行 self.ws=ch/restartReadLoop/
                // .ready，新通道永不 close（活连接泄漏）+ 僵尸 read task。故启用前守卫：主动关闭则关掉
                // 新通道并静默退出（incoming 已由 close() 收束，不再发 .ready）。
                if activeClose || Task.isCancelled { await ch.close(); return }
                self.ws = ch
                restartReadLoop()
                emitControl(.ready)
                return
            } catch is RejectHelloError {
                emitControl(.trustRevoked)
                finishIncomingTerminal(TransportError.channelClosed(reason: "信任已被撤销（RejectHello）"))
                return
            } catch {
                rtLog.error("重连尝试 \(attempt) 失败: \(String(describing: error), privacy: .public)")
                attempt += 1
            }
        }
        emitControl(.connectionFailed)
        finishIncomingTerminal(TransportError.channelClosed(reason: "重连重试达上限仍失败"))
    }

    // MARK: 前台/后台能耗管理

    /// 后台则挂起直到回前台（4.5）：重连循环每轮前调用。actor 串行保证判定与挂起原子。
    /// close() 主动断也会 resume 本等待（配合随后的 activeClose 检查退出），不泄漏 continuation。
    private func waitForForeground() async {
        if isForeground || activeClose { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // 单消费者（唯一重连循环）；防御性 resume 旧等待者避免覆盖泄漏。
            foregroundWaiter?.resume()
            foregroundWaiter = cont
        }
    }

    /// 前台/后台切换钩子（能耗）：回前台唤醒挂起的重连循环；退后台仅置标志（下一轮循环处挂起）。
    /// 签名带 `async` 精确匹配协议要求，确保覆写默认空实现（同名 async 要求 + 默认实现时，
    /// actor 的同步方法不会被识别为见证，须显式 async 才正确覆写）。
    func setForeground(_ active: Bool) async {
        isForeground = active
        if active {
            foregroundWaiter?.resume()
            foregroundWaiter = nil
        }
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

    /// 首连握手编排：调 `channelFactory()` 造通道 → `performHandshakeOn` 跑完握手建 SecureSession →
    /// markHandshakeDone + 启 read loop。失败落 `.failed` + 终结 incoming（含首连收 RejectHello →
    /// 发 `.trustRevoked`），绝不静默挂起。
    private func performHandshake() async {
        guard let factory = channelFactory else {
            markHandshakeFailed(TransportError.notConnected); return
        }
        do {
            let ch = try await factory()
            do {
                try await performHandshakeOn(ch)
            } catch {
                await ch.close()
                throw error
            }
            // #1 竞态硬化：performHandshakeOn 的 await 期间可能有 close() 落地（置 activeClose、
            // cancel readTask、收束流）。若握手未在 await 上抛取消而成功返回，须在启用新通道前守卫：
            // 已主动关闭则关掉新通道防活连接泄漏，不 markHandshakeDone / 不启 read loop。
            // close() 已在 pending 时落 .failed 并收束 incoming（重复调用被守卫忽略）；此处 markHandshakeFailed
            // 亦兜住「仅 Task 取消而未经 close」的边角，避免 awaitHandshake/incoming 永挂。
            if activeClose || Task.isCancelled {
                await ch.close()
                markHandshakeFailed(TransportError.channelClosed(reason: "连接主动关闭"))
                incomingContinuation?.finish(throwing: TransportError.channelClosed(reason: "连接主动关闭"))
                incomingContinuation = nil
                return
            }
            self.ws = ch
            markHandshakeDone()
            startReadLoopIfNeeded()
        } catch let rej as RejectHelloError {
            rtLog.error("首连握手被拒(RejectHello): \(String(describing: rej.reason), privacy: .public)")
            emitControl(.trustRevoked)
            // 以可判别类型 .trustRevoked 冒泡（而非通用 channelClosed）：observeControl 尚未订阅
            // （只在 .ready 后订阅），冷启动首连被撤销时靠此错误让 ConnectionStore.connect 的 catch
            // 置位 needsRePairing 引导重新配对。
            markHandshakeFailed(TransportError.trustRevoked)
            incomingContinuation?.finish(throwing: TransportError.trustRevoked)
            incomingContinuation = nil
        } catch {
            rtLog.error("握手失败: \(String(describing: error), privacy: .public)")
            // 先落 .failed 保留真实握手错误类型给 awaitHandshake，再收束 incoming 流：
            // 握手失败时 read loop 从未启动（被 startReadLoopIfNeeded 的 .done 守卫挡住），
            // 故此处是唯一收束路径。不收束会让 JSONRPCClient pump（握手前就 for-await incoming）永久挂起。
            markHandshakeFailed(error)
            incomingContinuation?.finish(throwing: TransportError.channelClosed(reason: "\(error)"))
            incomingContinuation = nil
        }
    }

    /// 在**指定通道**上跑完 iPad 侧握手（首连与每次重连共用编排）：
    /// makeClientHello（受信任复连 proof 留空；ephemeral 每次新生成 → 前向保密）→ 发 / 收 ServerHello →
    /// **先判 RejectHello**（独有 kind tag，命中即抛 `RejectHelloError`）→ verifyServerHelloAndMakeClientAuth →
    /// TOFU 比对/首信（发 ClientAuth 前，受信任复连不省）→ 发 ClientAuth → finishClient 建 SecureSession →
    /// 消费第 4 条 SecureReady 持久化 stableSessionId → 回填 `self.session`。
    /// **不** markHandshakeDone / 启 read loop（由调用方按首连 vs 重连分别处理）。
    private func performHandshakeOn(_ ch: RelayWSChannel) async throws {
        guard let inputs = handshakeInputs else { throw TransportError.notConnected }
        let p = inputs.pairing
        guard let devIdentityPub = Data(base64Encoded: p.devIdentityPubB64) else {
            throw TransportError.proxyFailed("配对载荷开发机公钥非法")
        }
        let ephemeral = inputs.ephemeralProvider()   // 每次握手新 ephemeral（前向保密），身份复用
        let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let ipadDeviceId = inputs.ipadIdentity.publicKey.rawRepresentation.base64EncodedString()

        var clientHello = Handshake.makeClientHello(
            sessionId: p.sessionId, ipadDeviceId: ipadDeviceId,
            ipadIdentityPub: inputs.ipadIdentity.publicKey.rawRepresentation,
            ipadEphemeralPub: ephemeral.publicKey.rawRepresentation,
            clientNonce: clientNonce, pairingCode: p.pairingCode)
        // 受信任复连：proof 留空免一次性 pairingCode（判定权在 dev 侧信任列表）；验签 + TOFU 任何模式不省。
        if inputs.isTrustedReconnect { clientHello.pairingCodeProof = Data() }
        try await ch.sendText(String(decoding: try JSONEncoder().encode(clientHello), as: UTF8.self))

        guard let shText = try await ch.receiveText() else {
            throw TransportError.channelClosed(reason: "握手中连接关闭（等 ServerHello）")
        }
        // 先判 RejectHello（独有 `kind` tag；ServerHello 无 kind 故互不误解）：命中 → 抛错，
        // 首连冒泡为握手失败，重连触发 .trustRevoked 终态不再重连。首连与重连都判。
        if let rej = try? JSONDecoder().decode(RejectHello.self, from: Data(shText.utf8)), rej.kind == "reject" {
            throw RejectHelloError(reason: rej.reason)
        }
        let serverHello = try JSONDecoder().decode(ServerHello.self, from: Data(shText.utf8))

        let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: clientHello, serverHello: serverHello,
            devIdentityPub: devIdentityPub, ipadIdentity: inputs.ipadIdentity)

        // TOFU：验开发机签名通过后、发 ClientAuth 之前比对/首信（身份变更即拒，
        // 绝不向被替换身份的机器出示一次性口令）。受信任复连同样不省。
        try inputs.tofu.verifyOrTrust(machineKey: inputs.tofuMachineKey,
                                      presentedPub: devIdentityPub)

        try await ch.sendText(String(decoding: try JSONEncoder().encode(clientAuth), as: UTF8.self))

        let secure = try Handshake.finishClient(
            clientHello: clientHello, serverHello: serverHello,
            ipadEphemeral: ephemeral, devIdentityPub: devIdentityPub)

        // 发 ClientAuth 后、回填 session 前，多收一条 SecureReady（msg 4，加密帧）并消费：
        // dev 首配与复连都发。必须在启 read loop 之前消费，否则 read loop 会把这条加密帧当业务帧 yield。
        guard let readyText = try await ch.receiveText() else {
            throw TransportError.channelClosed(reason: "握手中连接关闭（等 SecureReady）")
        }
        let readyEnv = try SecureEnvelope(decoding: Data(readyText.utf8))
        let readyPlain = try secure.open(readyEnv)
        let secureReady = try JSONDecoder().decode(SecureReady.self, from: readyPlain)
        inputs.stableSessionStore.save(machineKey: inputs.tofuMachineKey,
                                       stableSessionId: secureReady.stableSessionId)

        self.session = secure
    }

    // MARK: MessageTransport

    func send(_ text: String) async throws {
        guard let session, let ws else { throw TransportError.notConnected }
        let env = try session.seal(Data(text.utf8))
        let frame = String(decoding: try env.encoded(), as: UTF8.self)
        try await ws.sendText(frame)
    }

    nonisolated func incoming() -> AsyncThrowingStream<String, Error> {
        // 首次取流即启动 read loop（在 actor 上下文中幂等启动）。
        Task { await self.startReadLoopIfNeeded() }
        return incomingStream
    }

    nonisolated func control() -> AsyncStream<TransportControlEvent> {
        controlStream
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
        // 先置主动 close 标志：read loop（可能被 ws.close 唤醒）据此判为终态而非瞬断，不进重连。
        activeClose = true
        readTask?.cancel()   // 若正处在重连循环，取消其退避挂起
        // 若重连循环正挂起等待回前台，唤醒它（随后的 activeClose 检查令其退出），避免 continuation 泄漏。
        foregroundWaiter?.resume()
        foregroundWaiter = nil
        await ws?.close()
        if case .pending = handshakeState {
            markHandshakeFailed(TransportError.channelClosed(reason: "连接主动关闭"))
        }
        incomingContinuation?.finish()
        incomingContinuation = nil
        controlContinuation?.finish()
        controlContinuation = nil
    }
}
