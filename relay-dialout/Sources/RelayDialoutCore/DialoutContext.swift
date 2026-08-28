import Foundation
import Crypto
import RelayProtocol

// MARK: - 开发机侧握手上下文（从可执行 target 抽到库，供单测）
//
// 帧类型判定：握手期收 ClientHello / ClientAuth（明文 JSON）；建通道后收 SecureEnvelope。
// 本类型整体 Sendable，供 ws handler 跨线程调用。

/// 握手编排失败原因（dev 侧一次性口令相关）。
public enum DialoutHandshakeError: Error, Equatable { case pairingExpired, pairingAlreadyUsed }

/// 承载握手所需 dev 侧材料与一次性口令，并维护握手状态。整体 Sendable。
///
/// 注入 `TrustStore`：首次配对握手成功后自动记信任（幂等），并为每台 iPad 记录/复用稳定
/// sessionId（首配采用启动房间号），随加密 SecureReady 回传（走已建通道，不明文过 relay）。
public final class DialoutContext: @unchecked Sendable {
    public let keyStore: DevKeyStore
    public let devDeviceId: String
    /// 本次运行占用的房间号。首配模式 = 启动随机生成（兼未来稳定 sessionId）；复连模式 = 信任记录里的稳定值。
    public let sessionId: String
    public let pairingCode: String
    public let expiresAt: Int64
    private let trust: TrustStore

    private let lock = NSLock()
    private var _pairingConsumed = false
    private var _session: SecureSession?
    private var _clientHello: ClientHello?
    private var _serverHello: ServerHello?
    // 每次握手新生成的 dev X25519 交换私钥（前向保密：不落盘、握手完成/失败即释放）。
    // 与 _clientHello/_serverHello 并列，受 lock 保护；hello 与 auth 必须用同一把。
    private var _eph: Curve25519.KeyAgreement.PrivateKey?
    // 当前在飞握手是否走受信任复连分支（在 handleClientHello 判定，供 handleClientAuth 决定是否
    // 施加一次性口令重放守卫）。首配=false（受 pairingConsumed 约束）；受信任复连=true（可重握手）。
    private var _currentHandshakeTrusted = false

    public init(keyStore: DevKeyStore, devDeviceId: String, sessionId: String,
                pairingCode: String, expiresAt: Int64, trust: TrustStore) {
        self.keyStore = keyStore; self.devDeviceId = devDeviceId; self.sessionId = sessionId
        self.pairingCode = pairingCode; self.expiresAt = expiresAt; self.trust = trust
    }

    /// pairingCode 是否已被消费（握手成功后置 true，再来的握手拒绝）。
    public var pairingConsumed: Bool { lock.lock(); defer { lock.unlock() }; return _pairingConsumed }
    public var session: SecureSession? { lock.lock(); defer { lock.unlock() }; return _session }
    public var hellos: (ClientHello, ServerHello)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = _clientHello, let s = _serverHello else { return nil }
        return (c, s)
    }

    /// 握手期入站帧的路由判定（缺陷 #1 dev 侧）。
    ///
    /// dev 拨出是常驻连接：iPad 弱网重连会在同一 ws 上再发一个新 `ClientHello`（新 ephemeral），
    /// dispatch 层必须据帧类型区分「(重)握手起始」与「握手收尾 ClientAuth」，不能因 `hellos`
    /// 已就绪就一律当 ClientAuth（旧缺陷：新 Hello 被 `handleClientAuth` 解失败后 return 丢弃）。
    public enum InboundHandshakeRoute: Equatable { case clientHello, clientAuth }

    /// 纯函数分类：能按 `ClientHello` 解出即 `.clientHello`，否则 `.clientAuth`。
    ///
    /// `ClientHello` 与 `ClientAuth` 的 JSON 必填字段不相交——前者独有
    /// `ipadIdentityPub`/`ipadEphemeralPub`/`clientNonce`/`pairingCodeProof`/`protocolVersion`，
    /// 后者独有 `keyEpoch`/`ipadSignature`——故按 `ClientHello` 试解无误判（红测实证 decode 不相交）。
    /// 不改协议、不加显式 kind tag，守零知识（relay 不参与，dev 侧本地判帧类型）。
    public static func classifyHandshakeFrame(_ data: Data) -> InboundHandshakeRoute {
        if (try? JSONDecoder().decode(ClientHello.self, from: data)) != nil { return .clientHello }
        return .clientAuth
    }

    /// 返回非 nil 表示 dev 应向 iPad 发该 RejectHello 后关连接（而非静默断/继续）。
    /// 未受信任且未持有效 proof（空 proof）→ .untrusted（防降级：判定权在 dev 侧）。
    /// 已在信任列表则 nil（走受信任握手）；未受信任但带 proof 则 nil（走首配校验）。
    public func rejectHelloIfUnauthorized(_ hello: ClientHello) throws -> RejectHello? {
        let ipadPub = hello.ipadIdentityPub.base64EncodedString()
        if trust.record(forPubB64: ipadPub) != nil { return nil }   // 受信任 → 走受信任握手
        if hello.pairingCodeProof.isEmpty {                         // 未受信任 + 空 proof → 拒
            return try Handshake.makeRejectHello(clientHello: hello, reason: .untrusted,
                                                 devIdentity: keyStore.identity)
        }
        return nil   // 未受信任但带 proof → 交首配路径校验
    }

    /// Convert a locally classified ClientHello failure into an authenticated wire rejection.
    /// Unknown/internal failures remain a silent close so implementation details are not exposed.
    public func rejectHello(for error: Error, clientHello: ClientHello) throws -> RejectHello? {
        let reason: RejectReason
        if let dialoutError = error as? DialoutHandshakeError {
            switch dialoutError {
            case .pairingExpired, .pairingAlreadyUsed: reason = .pairingInvalid
            }
        } else if let handshakeError = error as? HandshakeError {
            switch handshakeError {
            case .pairingCodeMismatch: reason = .pairingInvalid
            case .versionMismatch: reason = .versionMismatch
            case .badServerSignature, .badClientSignature: return nil
            }
        } else {
            return nil
        }
        return try Handshake.makeRejectHello(clientHello: clientHello, reason: reason,
                                             devIdentity: keyStore.identity)
    }

    /// 处理 ClientHello → 返回要发回 relay 的 ServerHello 编码。
    ///
    /// 按 iPad 身份公钥是否在信任列表分两条路径：
    /// - 受信任复连：免一次性 pairingCode（不查 pairingConsumed/expiresAt），用 makeServerHelloTrusted；
    ///   每次都重置在飞握手状态，支持同一 context 上多次重握手（弱网重连）。
    /// - 未受信任首配：查 pairingConsumed/expiresAt，用 makeServerHello 验 proof（空 proof 必 HMAC 失败）。
    public func handleClientHello(_ data: Data) throws -> Data {
        let hello = try JSONDecoder().decode(ClientHello.self, from: data)
        let isTrusted = trust.record(forPubB64: hello.ipadIdentityPub.base64EncodedString()) != nil

        var nonce = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { nonce[i] = UInt8.random(in: 0...255) }

        // 本次握手专用的 dev X25519 交换私钥：每会话新生、不落盘（前向保密）。
        // hello 出示其公钥、auth 用同一把做 DH——必须是同一个 eph，否则 DH 对不上握手失败。
        let eph = Curve25519.KeyAgreement.PrivateKey()

        let serverHello: ServerHello
        if isTrusted {
            // 受信任复连：免 proof，不受一次性口令的消费/过期约束。
            serverHello = try Handshake.makeServerHelloTrusted(
                clientHello: hello,
                devDeviceId: devDeviceId,
                devIdentity: keyStore.identity,
                devEphemeralPub: eph.publicKey.rawRepresentation,
                serverNonce: Data(nonce),
                keyEpoch: 0
            )
        } else {
            // 首配路径：一次性口令约束照旧（空 proof 会在 makeServerHello 里 HMAC 失败 → 抛，防降级）。
            guard !pairingConsumed else { throw DialoutHandshakeError.pairingAlreadyUsed }
            guard Int64(Date().timeIntervalSince1970) < expiresAt else { throw DialoutHandshakeError.pairingExpired }
            serverHello = try Handshake.makeServerHello(
                clientHello: hello,
                devDeviceId: devDeviceId,
                devIdentity: keyStore.identity,
                devEphemeralPub: eph.publicKey.rawRepresentation,
                serverNonce: Data(nonce),
                keyEpoch: 0,
                pairingCode: pairingCode
            )
        }
        // 重握手支持：受信任路径每次都重置在飞握手状态（不被上一次的 hello/session 挡）。
        lock.lock()
        _clientHello = hello; _serverHello = serverHello; _eph = eph
        _currentHandshakeTrusted = isTrusted
        if isTrusted { _session = nil }
        lock.unlock()
        return try JSONEncoder().encode(serverHello)
    }

    /// 处理 ClientAuth → 验 iPad 签名建 dev 侧 SecureSession；
    /// 首次配对自动记信任（幂等）+ 生成/复用稳定 sessionId，返回加密后的 SecureReady 帧
    /// （走已建通道，供 handler 写回 ws；不明文过 relay）。
    ///
    /// 重放/重握手状态模型：
    /// - 首配路径（!trusted）：施加 `guard !pairingConsumed` 重放守卫，成功后置 pairingConsumed=true——
    ///   一次性口令用过即失效，relay 原样重放同一 ClientAuth 明文帧会被拒。
    /// - 受信任复连（trusted）：不施加该守卫、不置 pairingConsumed，允许幂等重复建 session（弱网重连）。
    /// verifyClientAuthAndFinish 验签任何路径都不省。
    public func handleClientAuth(_ data: Data) throws -> Data {
        let auth = try JSONDecoder().decode(ClientAuth.self, from: data)
        lock.lock()
        let trusted = _currentHandshakeTrusted
        let hellosSnapshot: (ClientHello, ServerHello)?
        if let c = _clientHello, let s = _serverHello { hellosSnapshot = (c, s) } else { hellosSnapshot = nil }
        let ephSnapshot = _eph
        let consumed = _pairingConsumed
        lock.unlock()

        // 重放守卫仅对首配一次性口令路径生效；受信任复连允许重握手。
        if !trusted { guard !consumed else { throw DialoutHandshakeError.pairingAlreadyUsed } }
        guard let (hello, serverHello) = hellosSnapshot, let eph = ephSnapshot else { throw HandshakeError.badClientSignature }

        let session: SecureSession
        do {
            // 用与 ServerHello 同一把 eph 做 DH（前向保密：本次握手专用私钥）。
            session = try Handshake.verifyClientAuthAndFinish(
                clientHello: hello,
                serverHello: serverHello,
                clientAuth: auth,
                devEphemeral: eph
            )
        } catch {
            // 握手失败即释放交换私钥，不留驻内存。
            lock.lock(); _eph = nil; lock.unlock()
            throw error
        }
        // 稳定 sessionId：已受信任的 iPad 复用其记录值；首次配对采用本次运行的启动房间号
        // （稳定房间前置：TOFU 落盘的就是首配房间号，房间从未变过，复连不再需要迁移）。
        // 注意（多 iPad 前提下需回头改）：当前"一 iPad 单房间"范围内此 fallback 安全；
        // 若未来放开多 iPad，复连模式下第二台 iPad 首配会 fallback 到同一注入值造成房间碰撞。
        let ipadPub = hello.ipadIdentityPub.base64EncodedString()
        let stable = trust.record(forPubB64: ipadPub)?.stableSessionId ?? sessionId

        // #2 事务性：先把信任落盘成功，之后才在锁内原子发布 _session + 消费一次性口令。
        // 落盘失败（IO/权限）→ 清握手态（_eph 释放，_session 保持 nil）、向上抛，
        // 绝不发布「已建通道但信任未落盘」的会话（防 fail-open）。
        do {
            // 自动记信任（首次写入、幂等更新，无额外交互确认）。
            try trust.trust(ipadPubB64: ipadPub, stableSessionId: stable, label: nil)
        } catch {
            lock.lock(); _eph = nil; lock.unlock()   // 与验签失败路径一致：释放交换私钥，_session/口令不动
            throw error
        }

        lock.lock()
        _session = session
        _eph = nil                                 // 握手完成即释放交换私钥
        if !trusted { _pairingConsumed = true }   // 仅首配消费一次性口令；受信任复连不置
        lock.unlock()

        // 构造并加密 SecureReady（走已建通道回传稳定 sessionId）。
        let ready = SecureReady(sessionId: hello.sessionId, keyEpoch: 0,
                                devDeviceId: devDeviceId, stableSessionId: stable)
        let env = try session.seal(JSONEncoder().encode(ready), kind: .secureReady)
        return try env.encoded()
    }
}
