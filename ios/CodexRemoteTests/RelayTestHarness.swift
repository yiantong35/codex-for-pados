import Foundation
import Crypto
import RelayProtocol
@testable import CodexRemote

/// 测试内「开发机侧」应答器：跑真 `Handshake` 调用（复刻 relay-dialout 握手逻辑），
/// 握手完成后对业务帧做「解密→加 "-echo"→加密」回声。@unchecked Sendable（锁保护状态）。
final class DevResponder: @unchecked Sendable {
    let devIdentity: Curve25519.Signing.PrivateKey
    let devEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devDeviceId = "dev-test"
    let pairingCode: String
    /// 首配握手第 4 条 SecureReady 回传给 iPad 的稳定 sessionId（撮合标签）。
    let stableSessionId: String

    private let lock = NSLock()
    private var _clientHello: ClientHello?
    private var _serverHello: ServerHello?
    private var _session: SecureSession?

    init(pairingCode: String, stableSessionId: String = "stable-default",
         devIdentity: Curve25519.Signing.PrivateKey = .init()) {
        self.pairingCode = pairingCode
        self.stableSessionId = stableSessionId
        self.devIdentity = devIdentity
    }

    var devIdentityPubB64: String { devIdentity.publicKey.rawRepresentation.base64EncodedString() }
    var establishedSession: SecureSession? { lock.lock(); defer { lock.unlock() }; return _session }

    /// 处理 iPad 发来一帧，返回要注入回 iPad 的应答帧（无则 nil）。
    func handle(_ frame: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let data = Data(frame.utf8)
        if let session = _session, let env = try? SecureEnvelope(decoding: data) {
            let plaintext = try session.open(env)
            let reply = try session.seal(plaintext + Data("-echo".utf8), kind: .appData)
            return String(decoding: try reply.encoded(), as: UTF8.self)
        }
        if _clientHello == nil, let hello = try? JSONDecoder().decode(ClientHello.self, from: data) {
            let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            // 空 proof = 受信任复连：不验 pairingCode（判定权在信任列表），验签在后续步骤照常。
            let sh: ServerHello
            if hello.pairingCodeProof.isEmpty {
                sh = try Handshake.makeServerHelloTrusted(
                    clientHello: hello, devDeviceId: devDeviceId, devIdentity: devIdentity,
                    devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
                    serverNonce: nonce, keyEpoch: 0)
            } else {
                sh = try Handshake.makeServerHello(
                    clientHello: hello, devDeviceId: devDeviceId, devIdentity: devIdentity,
                    devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
                    serverNonce: nonce, keyEpoch: 0, pairingCode: pairingCode)
            }
            _clientHello = hello; _serverHello = sh
            return String(decoding: try JSONEncoder().encode(sh), as: UTF8.self)
        }
        if let h = _clientHello, let s = _serverHello,
           let auth = try? JSONDecoder().decode(ClientAuth.self, from: data) {
            let session = try Handshake.verifyClientAuthAndFinish(
                clientHello: h, serverHello: s, clientAuth: auth, devEphemeral: devEphemeral)
            _session = session
            // 首配与复连都回发加密 SecureReady（msg 4），带 stableSessionId 供 iPad 持久化。
            let ready = SecureReady(sessionId: h.sessionId, keyEpoch: 0,
                                    devDeviceId: devDeviceId, stableSessionId: stableSessionId)
            let env = try session.seal(JSONEncoder().encode(ready), kind: .secureReady)
            return String(decoding: try env.encoded(), as: UTF8.self)
        }
        return nil
    }
}

/// 回环 ws：iPad 发出的帧立即交 DevResponder 处理，应答帧入 iPad 收队列。
/// 握手在内存里确定性跑完，不触真网络、不轮询。
actor LoopbackRelayWSChannel: RelayWSChannel {
    private let onSend: @Sendable (String) throws -> String?
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false

    init(onSend: @escaping @Sendable (String) throws -> String?) { self.onSend = onSend }

    func sendText(_ text: String) async throws {
        if let reply = try onSend(text) { deliver(reply) }
    }
    func receiveText() async throws -> String? {
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { self.waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(returning: nil); waiter = nil }
    var isClosedForTesting: Bool { closed }

    private func deliver(_ text: String) {
        if let w = waiter { waiter = nil; w.resume(returning: text) } else { pending.append(text) }
    }
    func inject(_ text: String) { deliver(text) }
}
