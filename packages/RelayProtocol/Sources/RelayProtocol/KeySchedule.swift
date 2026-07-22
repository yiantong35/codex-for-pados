import Foundation
import Crypto

/// 从 X25519 共享密钥派生方向分离的 AES-256-GCM 密钥。
public struct KeySchedule {
    public struct Context: Sendable {
        public let sessionId: String, devDeviceId: String, ipadDeviceId: String, keyEpoch: UInt32
        public init(sessionId: String, devDeviceId: String, ipadDeviceId: String, keyEpoch: UInt32) {
            self.sessionId = sessionId; self.devDeviceId = devDeviceId
            self.ipadDeviceId = ipadDeviceId; self.keyEpoch = keyEpoch
        }
    }

    public struct DirectionalKeys: Sendable {
        let ipadToDev: SymmetricKey
        let devToIpad: SymmetricKey
        /// 指定发送方对应的加密密钥（收端用同一函数取对方的“发密钥”解密）。
        public func sendKey(as sender: RelayPeer) -> SymmetricKey {
            sender == .iPad ? ipadToDev : devToIpad
        }
    }

    public static func derive(myEphemeral: Curve25519.KeyAgreement.PrivateKey,
                              peerEphemeralPub: Curve25519.KeyAgreement.PublicKey,
                              transcript: Data,
                              context ctx: Context) throws -> DirectionalKeys {
        let shared = try myEphemeral.sharedSecretFromKeyAgreement(with: peerEphemeralPub)
        let salt = Data(SHA256.hash(data: transcript))
        let baseInfo = [RelayProtocolVersion.tag, ctx.sessionId, ctx.devDeviceId,
                        ctx.ipadDeviceId, String(ctx.keyEpoch)].joined(separator: "|")
        func key(_ dir: String) -> SymmetricKey {
            let info = Data((baseInfo + "|" + dir).utf8)
            return shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        }
        return DirectionalKeys(ipadToDev: key("ipadToDev"), devToIpad: key("devToIpad"))
    }
}

#if !canImport(CryptoKit)
// Apple 平台的 CryptoKit 已让 SymmetricKey 遵循 Equatable；仅在非 Apple 平台补充。
extension SymmetricKey: @retroactive Equatable {
    public static func == (l: SymmetricKey, r: SymmetricKey) -> Bool {
        l.withUnsafeBytes { a in r.withUnsafeBytes { b in a.count == b.count && a.elementsEqual(b) } }
    }
}
#endif
