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

    private let lock = NSLock()
    private var _clientHello: ClientHello?
    private var _serverHello: ServerHello?
    private var _session: SecureSession?

    init(pairingCode: String, devIdentity: Curve25519.Signing.PrivateKey = .init()) {
        self.pairingCode = pairingCode
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
            let reply = try session.seal(plaintext + Data("-echo".utf8))
            return String(decoding: try reply.encoded(), as: UTF8.self)
        }
        if _clientHello == nil, let hello = try? JSONDecoder().decode(ClientHello.self, from: data) {
            let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let sh = try Handshake.makeServerHello(
                clientHello: hello, devDeviceId: devDeviceId, devIdentity: devIdentity,
                devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
                serverNonce: nonce, keyEpoch: 0, pairingCode: pairingCode)
            _clientHello = hello; _serverHello = sh
            return String(decoding: try JSONEncoder().encode(sh), as: UTF8.self)
        }
        if let h = _clientHello, let s = _serverHello,
           let auth = try? JSONDecoder().decode(ClientAuth.self, from: data) {
            _session = try Handshake.verifyClientAuthAndFinish(
                clientHello: h, serverHello: s, clientAuth: auth, devEphemeral: devEphemeral)
            return nil
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

    private func deliver(_ text: String) {
        if let w = waiter { waiter = nil; w.resume(returning: text) } else { pending.append(text) }
    }
    func inject(_ text: String) { deliver(text) }
}
