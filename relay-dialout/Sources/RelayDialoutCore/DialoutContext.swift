import Foundation
import RelayProtocol

// MARK: - 开发机侧握手上下文（从可执行 target 抽到库，供单测）
//
// 帧类型判定：握手期收 ClientHello / ClientAuth（明文 JSON）；建通道后收 SecureEnvelope。
// 本类型整体 Sendable，供 ws handler 跨线程调用。

/// 握手编排失败原因（dev 侧一次性口令相关）。
public enum DialoutHandshakeError: Error, Equatable { case pairingExpired, pairingAlreadyUsed }

/// 生成 URL-safe 的随机 token（stableSessionId / 一次性口令风格，与 main.swift randomToken 一致）。
func randomStableToken(byteCount: Int = 18) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// 承载握手所需 dev 侧材料与一次性口令，并维护握手状态。整体 Sendable。
///
/// 注入 `TrustStore`：首次配对握手成功后自动记信任（幂等），并为每台 iPad 生成/复用一个稳定
/// sessionId，随加密 SecureReady 回传（走已建通道，不明文过 relay）。
public final class DialoutContext: @unchecked Sendable {
    public let keyStore: DevKeyStore
    public let devDeviceId: String
    public let pairingCode: String
    public let expiresAt: Int64
    private let trust: TrustStore

    private let lock = NSLock()
    private var _pairingConsumed = false
    private var _session: SecureSession?
    private var _clientHello: ClientHello?
    private var _serverHello: ServerHello?

    public init(keyStore: DevKeyStore, devDeviceId: String, pairingCode: String,
                expiresAt: Int64, trust: TrustStore) {
        self.keyStore = keyStore; self.devDeviceId = devDeviceId
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

    /// 处理 ClientHello → 返回要发回 relay 的 ServerHello 编码。
    public func handleClientHello(_ data: Data) throws -> Data {
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

    /// 处理 ClientAuth → 验 iPad 签名建 dev 侧 SecureSession，pairingCode 失效；
    /// 首次配对自动记信任（幂等）+ 生成/复用稳定 sessionId，返回加密后的 SecureReady 帧
    /// （走已建通道，供 handler 写回 ws；不明文过 relay）。
    public func handleClientAuth(_ data: Data) throws -> Data {
        // 重放守卫：会话已建立后 relay（不可信中转）若原样重放同一 ClientAuth 明文帧，
        // 必须直接拒绝，不能重新走一遍验签/建 session/重发 SecureReady。
        guard !pairingConsumed else { throw DialoutHandshakeError.pairingAlreadyUsed }
        let auth = try JSONDecoder().decode(ClientAuth.self, from: data)
        guard let (hello, serverHello) = hellos else { throw HandshakeError.badClientSignature }
        let session = try Handshake.verifyClientAuthAndFinish(
            clientHello: hello,
            serverHello: serverHello,
            clientAuth: auth,
            devEphemeral: keyStore.exchange
        )
        lock.lock(); _session = session; _pairingConsumed = true; lock.unlock()  // 一次性口令用过即失效

        // 稳定 sessionId：已受信任的 iPad 复用其记录值；首次配对新生成。每台 iPad 各一个。
        let ipadPub = hello.ipadIdentityPub.base64EncodedString()
        let stable = trust.record(forPubB64: ipadPub)?.stableSessionId ?? randomStableToken()
        // 自动记信任（首次写入、幂等更新，无额外交互确认）。
        try trust.trust(ipadPubB64: ipadPub, stableSessionId: stable, label: nil)

        // 构造并加密 SecureReady（走已建通道回传稳定 sessionId）。
        let ready = SecureReady(sessionId: hello.sessionId, keyEpoch: 0,
                                devDeviceId: devDeviceId, stableSessionId: stable)
        let env = try session.seal(JSONEncoder().encode(ready))
        return try env.encoded()
    }
}
