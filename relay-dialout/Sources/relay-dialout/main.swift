import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import Crypto
import RelayProtocol
import RelayDialoutCore

// MARK: - 开发机侧拨出程序（编排入口）
//
// 职责：
//  1. 加载 DevKeyStore（~/.codex-relay-dialout/），生成一次性 pairingCode + sessionId + 过期时间，
//     打印 codexrelay:// 配对载荷到终端（供手动搬到 iPad）。
//  2. NIO ws 客户端拨出 relay（role=devMachine，路径 /relay/{sessionId}，x-role header）。
//  3. 开发机侧握手：ClientHello → makeServerHello（验 pairingCodeProof）→ ServerHello →
//     ClientAuth → verifyClientAuthAndFinish（验 iPad 签名）→ dev 侧 SecureSession。
//  4. 启 ProxyBridge，双向桥接：relay 收 SecureEnvelope → session.open → bridge.write；
//     bridge.incoming 明文 → session.seal → env.encoded() → ws 发 relay。
//  5. pairingCode 用过一次即失效（握手成功后置内存标记）。
//
// 本 task 求编译通过 + 逻辑正确；端到端由 Task 13/真机验证。ws 接线复杂处标注 TODO。

// MARK: 配置（环境变量 / 默认）
let env = ProcessInfo.processInfo.environment
let relayURL = env["RELAY_URL"] ?? "wss://relay.example.com"
let sockPath = env["CONTROL_SOCK"] ?? "\(NSHomeDirectory())/.codex/control.sock"
let codexPath = env["CODEX_PATH"] ?? "codex"
let keyDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-relay-dialout")

// MARK: 1. 密钥 + 配对载荷
let keyStore = try DevKeyStore(dir: keyDir)
let devDeviceId = env["DEV_DEVICE_ID"] ?? "dev-\(UUID().uuidString.prefix(8))"

func randomToken(byteCount: Int = 18) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let sessionId = randomToken(byteCount: 12)
let pairingCode = randomToken(byteCount: 12)
let expiresAt = Int64(Date().timeIntervalSince1970) + 600  // now + 600s

let payload = PairingPayload(
    relayURL: relayURL,
    sessionId: sessionId,
    devIdentityPubB64: keyStore.identityPublicKeyRaw.base64EncodedString(),
    pairingCode: pairingCode,
    expiresAt: expiresAt
)

print("=== relay-dialout ready ===")
print("将下面配对载荷搬到 iPad（10 分钟内有效）：")
print(payload.toURLString())
print("===========================")

// MARK: 握手上下文 + 状态（Sendable，脱离 main-actor 隔离，供 ws handler 调用）
//
// 帧类型判定：握手期收 ClientHello / ClientAuth（明文 JSON）；建通道后收 SecureEnvelope。
enum DialoutHandshakeError: Error { case pairingExpired, pairingAlreadyUsed }

/// 承载握手所需 dev 侧材料与一次性口令，并维护握手状态。整体 Sendable。
final class DialoutContext: @unchecked Sendable {
    let keyStore: DevKeyStore
    let devDeviceId: String
    let pairingCode: String
    let expiresAt: Int64

    private let lock = NSLock()
    private var _pairingConsumed = false
    private var _session: SecureSession?
    private var _clientHello: ClientHello?
    private var _serverHello: ServerHello?

    init(keyStore: DevKeyStore, devDeviceId: String, pairingCode: String, expiresAt: Int64) {
        self.keyStore = keyStore; self.devDeviceId = devDeviceId
        self.pairingCode = pairingCode; self.expiresAt = expiresAt
    }

    /// pairingCode 是否已被消费（握手成功后置 true，再来的握手拒绝）。
    var pairingConsumed: Bool { lock.lock(); defer { lock.unlock() }; return _pairingConsumed }
    var session: SecureSession? { lock.lock(); defer { lock.unlock() }; return _session }
    var hellos: (ClientHello, ServerHello)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = _clientHello, let s = _serverHello else { return nil }
        return (c, s)
    }

    /// 处理 ClientHello → 返回要发回 relay 的 ServerHello 编码。
    func handleClientHello(_ data: Data) throws -> Data {
        guard !pairingConsumed else { throw DialoutHandshakeError.pairingAlreadyUsed }
        guard Int64(Date().timeIntervalSince1970) < expiresAt else { throw DialoutHandshakeError.pairingExpired }
        let hello = try JSONDecoder().decode(ClientHello.self, from: data)
        var nonce = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { nonce[i] = UInt8.random(in: 0...255) }
        let serverHello = try Handshake.makeServerHello(
            clientHello: hello,
            devDeviceId: devDeviceId,
            devIdentity: keyStore.identity,
            devEphemeralPub: keyStore.exchange.publicKey.rawRepresentation,
            serverNonce: Data(nonce),
            keyEpoch: 0,
            pairingCode: pairingCode
        )
        lock.lock(); _clientHello = hello; _serverHello = serverHello; lock.unlock()
        return try JSONEncoder().encode(serverHello)
    }

    /// 处理 ClientAuth → 验 iPad 签名，建 dev 侧 SecureSession，pairingCode 失效。
    func handleClientAuth(_ data: Data) throws {
        let auth = try JSONDecoder().decode(ClientAuth.self, from: data)
        guard let (hello, serverHello) = hellos else { throw HandshakeError.badClientSignature }
        let session = try Handshake.verifyClientAuthAndFinish(
            clientHello: hello,
            serverHello: serverHello,
            clientAuth: auth,
            devEphemeral: keyStore.exchange
        )
        lock.lock(); _session = session; _pairingConsumed = true; lock.unlock()  // 一次性口令用过即失效
    }
}
let context = DialoutContext(keyStore: keyStore, devDeviceId: devDeviceId,
                             pairingCode: pairingCode, expiresAt: expiresAt)

// MARK: 2/3. NIO ws 客户端拨出 relay + 帧分发
//
// TODO(Task 13/集成): 下面为 ws 客户端拨出骨架。关键点：
//   - ClientBootstrap 连到 relayURL 的 host:port，addHTTPClientHandlers，
//     NIOWebSocketClientUpgrader 发 GET /relay/{sessionId} + header x-role: devMachine。
//   - upgradePipelineHandler 里装 DialoutWSHandler，按帧分发到上面的 handshake 函数；
//     建通道后收 SecureEnvelope → session.open → bridge.write，
//     bridge.incoming 明文 → session.seal → env.encoded() → 写 ws text frame。
//   - 断线/过期清理：调用 bridge.terminate() 只停自己 spawn 的 proxy 子进程。
// 端到端拨号编排靠集成阶段落地；此处先固化握手/桥接主干逻辑与类型。

/// ws 帧处理器：把 relay 收到的帧路由到握手/桥接逻辑，把 proxy 输出加密回发。
final class DialoutWSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let bridge: ProxyBridge
    private let context: DialoutContext
    private var bridgeStarted = false

    init(bridge: ProxyBridge, context: DialoutContext) {
        self.bridge = bridge; self.context = context
    }

    func channelRead(context ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            var buf = frame.unmaskedData
            let bytes = buf.readBytes(length: buf.readableBytes) ?? []
            handlePayload(Data(bytes), ctx: ctx)
        case .connectionClose:
            bridge.terminate()   // 只停自己 spawn 的 proxy 子进程
            ctx.close(promise: nil)
        default:
            break
        }
    }

    /// 分发一帧原始字节：先按 SecureEnvelope 解，失败再按握手明文帧处理。
    private func handlePayload(_ data: Data, ctx: ChannelHandlerContext) {
        if let session = context.session, let env = try? SecureEnvelope(decoding: data) {
            // 建通道后：密文 → 解密 → 写 proxy stdin。
            guard let plaintext = try? session.open(env) else { return }
            ensureBridgeStarted()
            if let s = String(data: plaintext, encoding: .utf8) {
                bridge.write(s)
            }
            return
        }
        // 握手期：先试 ClientAuth（更晚），再试 ClientHello。
        if context.hellos != nil, (try? context.handleClientAuth(data)) != nil {
            // 握手完成，启桥并开始把 proxy 输出加密回发。
            ensureBridgeStarted()
            pumpBridgeOutbound(ctx: ctx)
            return
        }
        if let serverHelloData = try? context.handleClientHello(data) {
            sendFrame(serverHelloData, ctx: ctx)
        }
    }

    private func ensureBridgeStarted() {
        guard !bridgeStarted else { return }
        bridgeStarted = true
        do { try bridge.start() } catch { /* TODO(集成): 上报启动失败 */ }
    }

    /// proxy stdout 明文 → session.seal → SecureEnvelope → ws text frame。
    private func pumpBridgeOutbound(ctx: ChannelHandlerContext) {
        let channel = ctx.channel
        let ctxRef = context
        Task {
            for await line in bridge.incoming {
                guard let session = ctxRef.session,
                      let env = try? session.seal(Data(line.utf8)),
                      let encoded = try? env.encoded() else { continue }
                channel.eventLoop.execute {
                    var buf = channel.allocator.buffer(capacity: encoded.count)
                    buf.writeBytes(encoded)
                    let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                    channel.writeAndFlush(frame, promise: nil)
                }
            }
        }
    }

    private func sendFrame(_ data: Data, ctx: ChannelHandlerContext) {
        var buf = ctx.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        ctx.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }
}

// MARK: ws 拨出骨架
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bridge = ProxyBridge(codexPath: codexPath, sockPath: sockPath)

guard let url = URL(string: relayURL), let host = url.host else {
    print("RELAY_URL 无效: \(relayURL)")
    exit(1)
}
let isTLS = url.scheme == "wss"
let port = url.port ?? (isTLS ? 443 : 80)
let uri = "/relay/\(sessionId)"

// TODO(Task 13/集成): 补 TLS（wss）ClientTLSConfiguration；此骨架先落 ws 明文拨号编排。
let bootstrap = ClientBootstrap(group: group)
    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .channelInitializer { channel in
        let httpHandler = HTTPInitialRequestHandler(host: host, uri: uri)
        let upgrader = NIOWebSocketClientUpgrader(
            upgradePipelineHandler: { (channel, _) in
                channel.pipeline.addHandler(DialoutWSHandler(bridge: bridge, context: context))
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

do {
    let channel = try bootstrap.connect(host: host, port: port).wait()
    print("relay-dialout 已拨出 \(host):\(port)\(uri) (role=devMachine)")
    try channel.closeFuture.wait()
} catch {
    print("relay-dialout 拨出失败: \(error)")
    bridge.terminate()   // 精确停自己 spawn 的 proxy 子进程
    try? group.syncShutdownGracefully()
    exit(1)
}
try? group.syncShutdownGracefully()
