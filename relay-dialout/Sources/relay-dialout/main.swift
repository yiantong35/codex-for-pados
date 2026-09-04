import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import Crypto
import RelayProtocol
import RelayDialoutCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 开发机侧拨出程序（编排入口）
//
// 职责：
//  1. 加载 DevKeyStore（~/.codex-relay-dialout/），生成一次性 pairingCode + sessionId + 过期时间，
//     打印 codexrelay:// 配对载荷到终端（供手动搬到 iPad）。
//  2. NIO ws 客户端拨出 relay（role=devMachine，路径 /relay/{sessionId}，x-role header）。
//  3. 开发机侧握手：ClientHello → makeServerHello（验 pairingCodeProof）→ ServerHello →
//     ClientAuth → verifyClientAuthAndFinish（验 iPad 签名）→ dev 侧 SecureSession。
//  4. 启 DaemonBridge，双向桥接：relay 收 SecureEnvelope → session.open → bridge.write；
//     bridge.incoming 明文 → session.seal → env.encoded() → ws 发 relay。
//  5. pairingCode 用过一次即失效（握手成功后置内存标记）。
//
// ws 客户端拨出 relay 已落地（DialoutWSHandler 收发 + 帧分发已由 RelayDialoutCore 测试覆盖）；
// 端到端拨号由真机验收。

// MARK: 配置（环境变量 / 默认）
let env = ProcessInfo.processInfo.environment
let relayURL = env["RELAY_URL"] ?? "wss://relay.example.com"
let codexPath = env["CODEX_PATH"] ?? "codex"
let keyDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-relay-dialout")

// MARK: 1. 密钥 + 信任存储
let keyStore = try DevKeyStore(dir: keyDir)
let devDeviceId = env["DEV_DEVICE_ID"] ?? "dev-\(UUID().uuidString.prefix(8))"
let trustStore = try TrustStore(dir: keyDir)

func randomToken(byteCount: Int = 18) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: 撤销信任 CLI（--forget / --forget-all / --list-trusted）
//
// 必须在生成/打印任何一次性配对载荷之前分派：这几个管理命令只依赖 trustStore，
// 语义上不该产出配对信息。命中撤销/列出命令则执行后直接退出；
// 无匹配参数（.runDialout）才继续往下生成 pairingCode 并进入拨号流程。
switch parseTrustCommand(Array(CommandLine.arguments.dropFirst())) {
case .forget(let key):
    // 优先按 label 精确匹配，其次按公钥 b64 前缀匹配；找不到明确报错并非零退出。
    if let rec = trustStore.all().first(where: { $0.label == key || $0.ipadPubB64.hasPrefix(key) }) {
        try trustStore.revoke(ipadPubB64: rec.ipadPubB64)
        print("已撤销信任：\(rec.label ?? rec.ipadPubB64)")
    } else {
        print("未找到匹配的受信任 iPad：\(key)")
        exit(1)
    }
    exit(0)
case .forgetAll:
    try trustStore.clearAll()
    print("已清空全部信任")
    exit(0)
case .list:
    let all = trustStore.all()
    if all.isEmpty {
        print("（无受信任 iPad）")
    } else {
        for r in all {
            print("- \(r.label ?? "(无标签)")  pub=\(r.ipadPubB64.prefix(12))…  sid=\(r.stableSessionId)")
        }
    }
    exit(0)
case .runDialout:
    break   // 继续下面的配对载荷生成 + 拨号流程
case .invalid(let msg):
    print("参数错误：\(msg)")
    exit(2)
}

// MARK: 2. 房间选择 + 一次性配对载荷（仅 .runDialout 才会执行到这里）
//
// 一 iPad + 多开发机：本机至多信任一台 iPad。有则复连模式开其稳定房间（不吐配对载荷）；
// 无则首配模式开随机房间（照旧打印 codexrelay:// 配对载荷）。不考虑多 iPad/多房间。
let trustedRecord = trustStore.all().first
let sessionId: String
let reconnectMode: Bool
if let rec = trustedRecord {
    sessionId = rec.stableSessionId
    reconnectMode = true
} else {
    // 首配：该随机 token 同时充当首配房间号与未来稳定 sessionId——TOFU 成功落盘的就是它，
    // 房间从未变过（稳定房间前置）。轮换出口 = --forget-all 清信任后下次启动生成新随机房间。
    sessionId = randomToken(byteCount: 12)
    reconnectMode = false
}
let pairingCode = randomToken(byteCount: 12)   // 首配用；复连模式下 iPad 走空 proof 不生效
let expiresAt = Int64(Date().timeIntervalSince1970) + 600  // now + 600s

if reconnectMode {
    print("等待受信任 iPad 复连（房间 \(sessionId.prefix(8))…）。如需重新配对，先运行 relay-dialout --forget-all")
} else {
    let payload = PairingPayload(
        relayURL: relayURL,
        sessionId: sessionId,
        devIdentityPubB64: keyStore.identityPublicKeyRaw.base64EncodedString(),
        pairingCode: pairingCode,
        expiresAt: expiresAt
    )
    print("=== relay-dialout ready ===")
    print("扫码或将下面配对载荷搬到 iPad（10 分钟内有效）：")
    print("")
    if let qr = try? TerminalQRCode.halfBlockString(for: payload.toURLString()) {
        print(qr)
    }
    print(payload.toURLString())   // 明文兜底：终端不支持扫码时手动搬运
    print("===========================")
}

// MARK: 握手上下文 + 状态（DialoutContext 已抽到 RelayDialoutCore 库，供单测）
//
// 帧类型判定：握手期收 ClientHello / ClientAuth（明文 JSON）；建通道后收 SecureEnvelope。
// 注入 TrustStore：首次配对自动记信任 + 每台 iPad 稳定 sessionId + 加密回传 SecureReady。
// 注入 sessionId：本次运行占用的房间号，首配 TOFU 落盘采用它（稳定房间前置）。
let context = DialoutContext(keyStore: keyStore, devDeviceId: devDeviceId, sessionId: sessionId,
                             pairingCode: pairingCode, expiresAt: expiresAt, trust: trustStore)

// MARK: 2/3. NIO ws 客户端拨出 relay + 帧分发（wss 前置 TLS，ws 明文保留本地测试）
//
// ws 客户端拨出 relay 的实现（已落地）：
//   - ClientBootstrap 连到 relayURL 的 host:port，addHTTPClientHandlers，
//     NIOWebSocketClientUpgrader 发 GET /relay/{sessionId} + header x-role: devMachine。
//   - upgradePipelineHandler 里装 DialoutWSHandler，按帧分发到上面的 handshake 函数；
//     建通道后收 SecureEnvelope → session.open → bridge.write，
//     bridge.incoming 明文 → session.seal → env.encoded() → 写 ws text frame。
//   - relay 瞬断由 supervisor 重拨；bridge 由 sessionBridge 管理——每次握手 = 一个全新 app-server daemon，
//     重握手成功时精确回收旧 daemon，杜绝 iPad 重连后重新 initialize 命中同一已初始化 daemon（-32600）。

final class PendingDialoutChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false

    func register(_ channel: Channel) {
        lock.lock()
        self.channel = channel
        let shouldClose = cancelled
        lock.unlock()
        if shouldClose { channel.close(promise: nil) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let channel = self.channel
        lock.unlock()
        channel?.close(promise: nil)
    }
}

/// ws 帧处理器：把 relay 收到的帧路由到握手/桥接逻辑，把 proxy 输出加密回发。
final class DialoutWSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let sessionBridge: DialoutSessionBridge
    private let context: DialoutContext
    private let attempt: DialoutAttemptTracker
    private var outputAttachment: BridgeOutputRouter.Attachment?

    init(
        sessionBridge: DialoutSessionBridge,
        context: DialoutContext,
        attempt: DialoutAttemptTracker
    ) {
        self.sessionBridge = sessionBridge
        self.context = context
        self.attempt = attempt
    }

    func channelRead(context ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            var buf = frame.unmaskedData
            let bytes = buf.readBytes(length: buf.readableBytes) ?? []
            handlePayload(Data(bytes), ctx: ctx)
        case .connectionClose:
            ctx.close(promise: nil)
        default:
            break
        }
    }

    /// 瞬时 relay 断开只摘除当前输出 sink；bridge 由 sessionBridge 保留到终态/下一会话。
    func channelInactive(context ctx: ChannelHandlerContext) {
        if let outputAttachment { sessionBridge.router?.detach(outputAttachment) }
        outputAttachment = nil
        ctx.fireChannelInactive()
    }

    /// 分发一帧原始字节：先按 SecureEnvelope 解，失败再按握手明文帧处理。
    private func handlePayload(_ data: Data, ctx: ChannelHandlerContext) {
        if let session = context.session, let env = try? SecureEnvelope(decoding: data) {
            // 建通道后：密文 → 解密 → 写 proxy stdin。
            // dev 侧只期望 iPad 发来的应用数据帧；非预期 kind（如 secureReady）fail-closed 丢弃，不静默放行。
            guard env.kind == .appData else { return }
            guard let plaintext = try? session.open(env) else { return }
            guard ensureCurrentSessionStarted(ctx: ctx) else { return }   // 启桥失败已关连接，不再写
            if let s = String(data: plaintext, encoding: .utf8) {
                if let bridge = sessionBridge.bridge, !bridge.write(s) { ctx.close(promise: nil) }
            }
            return
        }
        // 连接层信号(如 relay 的 peer-left):dev 侧不据此动作,静默忽略,避免误入握手解析。
        if let sig = try? RelaySignal(decoding: data), sig.kind == RelaySignal.peerLeftKind {
            return
        }
        // 握手期分发（缺陷 #1 dev 侧）：dev 拨出常驻连接，iPad 弱网重连会在同一 ws 上再发新 ClientHello。
        // 按帧类型路由——绝不因 hellos 已就绪就把新 ClientHello 当迟到 ClientAuth 丢弃。
        // #2：不吞错——信任落盘失败必须冒泡，绝不因 try? 吞错而在信任未落盘时启 bridge。
        switch DialoutContext.classifyHandshakeFrame(data) {
        case .clientAuth:
            // 握手收尾：必须已有在飞握手（hellos 就绪）才处理，否则无 hello 上下文，静默丢弃。
            guard context.hellos != nil else { return }
            let readyFrame: Data
            do {
                readyFrame = try context.handleClientAuth(data)
            } catch {
                attempt.markTerminal(.trustRejected)
                ctx.close(promise: nil)
                return
            }
            // 握手完成：先加密回传 SecureReady（稳定 sessionId），再启桥并把 proxy 输出加密回发。
            sendFrame(readyFrame, ctx: ctx)   // 只发一次
            // 每次握手 = 一个全新 iPad 会话 = 一个全新 app-server daemon（回收旧 daemon，杜绝重连后 iPad
            // 重新 initialize 命中同一 daemon 拿 -32600 Already initialized）。失败 fail-closed 关连接。
            guard beginFreshSession(ctx: ctx) else { return }
            attachBridgeOutbound(ctx: ctx)
            attempt.markHealthy()
            return
        case .clientHello:
            // (重)握手起始：受信任复连的 handleClientHello 每次重置在飞握手态，支持连接内多次重握手。
            // 首配/防降级校验（rejectHelloIfUnauthorized + makeServerHello 验 proof）一律照旧，绝不降级。
            break   // 落到下方 ClientHello 处理
        }
        // （区别于静默断连，便于 iPad 侧展示明确原因，而非无提示卡住）。
        let decodedHello = try? JSONDecoder().decode(ClientHello.self, from: data)
        if let hello = decodedHello {
            do {
                if let reject = try context.rejectHelloIfUnauthorized(hello) {
                    sendFrame(try JSONEncoder().encode(reject), ctx: ctx)
                    attempt.markTerminal(.trustRejected)
                    ctx.close(promise: nil)
                    return
                }
            } catch {
                attempt.markTerminal(.trustRejected)
                ctx.close(promise: nil)
                return
            }
        }
        do {
            let serverHelloData = try context.handleClientHello(data)
            sendFrame(serverHelloData, ctx: ctx)
        } catch {
            if let hello = decodedHello,
               let reject = try? context.rejectHello(for: error, clientHello: hello),
               let encoded = try? JSONEncoder().encode(reject) {
                sendFrame(encoded, ctx: ctx)
            }
            attempt.markTerminal(.trustRejected)
            ctx.close(promise: nil)
        }
    }

    /// 每次握手完成调用：重建一个全新 app-server daemon 会话（回收旧 daemon，杜绝重连后 iPad 重新
    /// initialize 命中同一已初始化 daemon 拿 -32600 Already initialized）。启动失败**不吞**——回收旧会话
    /// 并关连接（fail-closed，让 iPad 明确感知断连而非收 SecureReady 后干等 initialize 超时）。
    /// 返回 false = 已失败并关连接，调用方须即停后续桥接。
    @discardableResult
    private func beginFreshSession(ctx: ChannelHandlerContext) -> Bool {
        do {
            try sessionBridge.beginSession()
            return true
        } catch {
            attempt.markTerminal(.bridgeFailed)
            ctx.close(promise: nil)       // 关连接：iPad 侧据此明确失败，不静默继续
            return false
        }
    }

    /// 防御性复核当前会话 daemon 已就绪（appData 分支）。逻辑上 beginSession() 已在握手完成时启动，
    /// 此处仅兜底；失败关连接（fail-closed）。
    @discardableResult
    private func ensureCurrentSessionStarted(ctx: ChannelHandlerContext) -> Bool {
        do {
            try sessionBridge.ensureCurrentStarted()
            return true
        } catch {
            attempt.markTerminal(.bridgeFailed)
            ctx.close(promise: nil)
            return false
        }
    }

    /// 全局 router 持续 drain proxy stdout；这里只替换当前物理连接 sink，不缓存断线数据。
    private func attachBridgeOutbound(ctx: ChannelHandlerContext) {
        guard let router = sessionBridge.router, let bridge = sessionBridge.bridge else { return }
        if let outputAttachment { router.detach(outputAttachment) }
        let channel = ctx.channel
        let ctxRef = context
        let bridgeRef = bridge
        outputAttachment = router.attach { line in
            guard let session = ctxRef.session else { return }
            let result: DialoutOutboundFrameBuildResult
            do { result = try DialoutOutboundFrameBuilder.build(line: line, session: session) }
            catch { return }
            let encoded: Data
            switch result {
            case .frame(let frame):
                encoded = frame
            case .rejectUpstream(let response):
                if !bridgeRef.write(response) {
                    channel.eventLoop.execute { channel.close(promise: nil) }
                }
                return
            case .dropped:
                return
            }
            channel.eventLoop.execute {
                var buf = channel.allocator.buffer(capacity: encoded.count)
                buf.writeBytes(encoded)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(frame, promise: nil)
            }
        }
        router.start()
    }

    private func sendFrame(_ data: Data, ctx: ChannelHandlerContext) {
        var buf = ctx.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        ctx.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }
}

// MARK: ws 拨出
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

final class DialoutStopRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (DialoutStopReason) -> Void)?
    private var pending: DialoutStopReason?

    func install(_ handler: @escaping @Sendable (DialoutStopReason) -> Void) {
        lock.lock()
        self.handler = handler
        let pending = self.pending
        self.pending = nil
        lock.unlock()
        if let pending { handler(pending) }
    }

    func request(_ reason: DialoutStopReason) {
        lock.lock()
        if let handler = self.handler {
            lock.unlock()
            handler(reason)
        } else {
            if pending == nil { pending = reason }
            lock.unlock()
        }
    }
}

let stopRelay = DialoutStopRelay()
// 每个握手会话对应一个全新 app-server daemon；重握手（iPad app 强杀重连等）成功时回收旧 daemon 并重生成，
// 杜绝 iPad 重连后重新 initialize 命中同一已初始化 daemon 拿 -32600 Already initialized。
let sessionBridge = DialoutSessionBridge(
    daemonFactory: { onAbnormalExit in
        DaemonBridge(codexPath: codexPath, onAbnormalExit: onAbnormalExit)
    },
    onBridgeExit: { stopRelay.request(.bridgeExited) }
)

guard let url = URL(string: relayURL), let host = url.host else {
    print("RELAY_URL 无效: \(relayURL)")
    exit(1)
}
let isTLS = url.scheme == "wss"
let port = url.port ?? (isTLS ? 443 : 80)
let uri = "/relay/\(sessionId)"

/// 发起 upgrade 的初始 HTTP 请求处理器（带 x-role: devMachine header）。
final class HTTPInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let uri: String
    init(host: String, uri: String) { self.host = host; self.uri = uri }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "x-role", value: RelayPeer.devMachine.rawValue)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // upgrade 成功后此 handler 被移除；升级前的响应体忽略。
    }
}

@Sendable func shutdownEventLoopGroup(_ group: EventLoopGroup) {
    try? group.syncShutdownGracefully()
}

let supervisor = DialoutSupervisor(
    connector: {
        let attempt = DialoutAttemptTracker()
        let pendingChannel = PendingDialoutChannel()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                pendingChannel.register(channel)
                let httpHandler = HTTPInitialRequestHandler(host: host, uri: uri)
                let tlsFuture: EventLoopFuture<Void> = isTLS
                    ? DialoutTLS.addClientTLS(to: channel, serverHostname: host)
                    : channel.eventLoop.makeSucceededFuture(())
                return tlsFuture.flatMap {
                    let upgrader = DialoutWebSocket.makeClientUpgrader(
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(DialoutWSHandler(
                                sessionBridge: sessionBridge,
                                context: context,
                                attempt: attempt
                            ))
                        }
                    )
                    let config = NIOHTTPClientUpgradeConfiguration(
                        upgraders: [upgrader],
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
                        .flatMap { channel.pipeline.addHandler(httpHandler) }
                }
            }

        let channel = try await withTaskCancellationHandler {
            try await bootstrap.connect(host: host, port: port).get()
        } onCancel: {
            pendingChannel.cancel()
        }
        print("relay-dialout 已拨出 \(host):\(port)\(uri) (role=devMachine)")
        try await withTaskCancellationHandler {
            try await channel.closeFuture.get()
        } onCancel: {
            pendingChannel.cancel()
        }
        return attempt.outcome
    },
    onShutdown: {
        // 先停 router（取消 stream，防向已停事件循环提交）+ 精确 terminate daemon（非阻塞），
        // 再停事件循环，最后等待精确 PID 完成 TERM/KILL 与 reap。
        sessionBridge.shutdownAll()
        shutdownEventLoopGroup(group)
        sessionBridge.awaitTermination()
    }
)

stopRelay.install { reason in
    Task { await supervisor.stop(reason) }
}

func makeSignalSource(_ signalNumber: Int32) -> DispatchSourceSignal {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { stopRelay.request(.cancelled) }
    source.resume()
    return source
}

// daemon 死后写侧撞破管道:进程级忽略 SIGPIPE,write 返回 EPIPE → throwing API 抛错 →
// drainWrites catch 可达(否则内核信号先杀进程 exit 141,catch 不可达)。
// NIO socket 自带 SO_NOSIGPIPE,此处无副作用。位置在 supervisor.run() 之前,先于一切 daemon 写入。
signal(SIGPIPE, SIG_IGN)
let signalSources = [makeSignalSource(SIGINT), makeSignalSource(SIGTERM)]
let stopReason = await supervisor.run()
signalSources.forEach { $0.cancel() }

switch stopReason {
case .cancelled:
    print("relay-dialout 已停止")
case .trustRejected:
    print("relay-dialout 因信任校验失败停止")
    exit(1)
case .bridgeExited:
    print("relay-dialout 因 proxy bridge 退出停止")
    exit(1)
case .bridgeFailed:
    print("relay-dialout 因 proxy bridge 启动失败停止")
    exit(1)
}
