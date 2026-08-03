import Foundation
import Crypto

public enum SecureSessionError: Error, Equatable {
    case replayOrOutOfOrder
    case wrongSender
    case decryptFailed
}

/// 一条已建立的加密会话：按方向密钥加解密，nonce 方向绑定 + 单调计数防重放。
public final class SecureSession: @unchecked Sendable {
    private let role: RelayPeer
    private let keys: KeySchedule.DirectionalKeys
    private let sessionId: String
    private let keyEpoch: UInt32
    private var outboundCounter: UInt64 = 0
    private var lastInbound: UInt64 = 0
    private let lock = NSLock()

    init(role: RelayPeer, keys: KeySchedule.DirectionalKeys, sessionId: String, keyEpoch: UInt32) {
        self.role = role; self.keys = keys; self.sessionId = sessionId; self.keyEpoch = keyEpoch
    }

    /// 12 字节 nonce：byte0 = 发送方标志(iPad=1/dev=2)，byte4..11 = 大端计数。
    private static func nonce(sender: RelayPeer, counter: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = sender == .iPad ? 1 : 2
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { raw in
            // 8 字节计数放到 bytes[4..11]
            for i in 0..<8 { bytes[4 + i] = raw[i] }
        }
        return try! AES.GCM.Nonce(data: Data(bytes))
    }

    public func seal(_ plaintext: Data, kind: RelayFrameKind) throws -> SecureEnvelope {
        lock.lock(); defer { lock.unlock() }
        outboundCounter += 1
        let counter = outboundCounter
        let key = keys.sendKey(as: role)
        let nonce = Self.nonce(sender: role, counter: counter)
        let aad = SecureEnvelope.headerAAD(v: RelayProtocolVersion.wire, keyEpoch: keyEpoch,
                                           sessionId: sessionId, sender: role, counter: counter, kind: kind)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return SecureEnvelope(v: RelayProtocolVersion.wire, sessionId: sessionId, keyEpoch: keyEpoch,
                              sender: role, counter: counter, kind: kind,
                              ciphertext: box.ciphertext, tag: box.tag)
    }

    public func open(_ env: SecureEnvelope) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard env.sender != role else { throw SecureSessionError.wrongSender }
        guard env.counter > lastInbound else { throw SecureSessionError.replayOrOutOfOrder }
        let key = keys.sendKey(as: env.sender)   // 用对方“发密钥”解
        let nonce = Self.nonce(sender: env.sender, counter: env.counter)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: env.ciphertext, tag: env.tag)
            // AAD = 整个明文 header 的规范编码；篡改任一 header 字段（含 kind）→ tag 失配 → 抛错。
            let pt = try AES.GCM.open(box, using: key, authenticating: env.aad())
            lastInbound = env.counter
            return pt
        } catch { throw SecureSessionError.decryptFailed }
    }
}
