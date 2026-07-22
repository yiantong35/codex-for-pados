import Foundation
import Crypto

/// 开发机侧 E2E 身份/交换密钥持久化。
///
/// 首次创建生成 Ed25519 身份密钥（握手签名）+ X25519 交换密钥（KeySchedule 派生），
/// 各自 `.rawRepresentation` 以 0600 权限写入 `dir` 下文件；已存在则从文件加载复用（幂等）。
///
/// ⚠️ 这两把密钥独立于 iPad SSH 密钥，是开发机侧 relay-e2e 专属身份/交换密钥。
public final class DevKeyStore {
    /// Ed25519 身份私钥，用于握手 devSignature。
    public let identity: Curve25519.Signing.PrivateKey
    /// X25519 交换私钥，用于 KeySchedule 派生方向密钥。
    public let exchange: Curve25519.KeyAgreement.PrivateKey

    /// 身份公钥 raw（放进 PairingPayload 供 iPad 带外验签）。
    public var identityPublicKeyRaw: Data { identity.publicKey.rawRepresentation }

    public init(dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let identityURL = dir.appendingPathComponent("identity.key")
        let exchangeURL = dir.appendingPathComponent("exchange.key")

        self.identity = try Self.loadOrCreateIdentity(at: identityURL)
        self.exchange = try Self.loadOrCreateExchange(at: exchangeURL)
    }

    private static func loadOrCreateIdentity(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        if let data = try? Data(contentsOf: url) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try writeSecret(key.rawRepresentation, to: url)
        return key
    }

    private static func loadOrCreateExchange(at url: URL) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try? Data(contentsOf: url) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try writeSecret(key.rawRepresentation, to: url)
        return key
    }

    /// 以 0600 权限原子写入密钥字节。
    private static func writeSecret(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
