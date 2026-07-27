import Foundation
import Crypto

/// 开发机侧 E2E 身份密钥持久化。
///
/// 首次创建生成 Ed25519 身份密钥（握手签名），`.rawRepresentation` 以 0600 权限写入 `dir`
/// 下文件；已存在则从文件加载复用（幂等）。
///
/// ⚠️ 身份密钥独立于 iPad SSH 密钥，是开发机侧 relay-e2e 专属身份密钥。
///
/// **前向保密**：X25519 交换密钥每会话新生成、绝不持久化（不再落盘复用）；仅 Ed25519 身份
/// 密钥持久化。交换私钥的生成/持有由 `DialoutContext` 在每次握手内完成。
public final class DevKeyStore {
    /// 密钥文件存在但无法读取/解析（权限损坏、IO 故障、内容损坏）。
    /// 绝不静默用新密钥覆盖——否则开发机身份会静默丢失。
    public enum DevKeyStoreError: Error, Equatable {
        case unreadableKeyFile(String)
        case corruptedKeyFile(String)
    }

    /// Ed25519 身份私钥，用于握手 devSignature。
    public let identity: Curve25519.Signing.PrivateKey

    /// 身份公钥 raw（放进 PairingPayload 供 iPad 带外验签）。
    public var identityPublicKeyRaw: Data { identity.publicKey.rawRepresentation }

    public init(dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let identityURL = dir.appendingPathComponent("identity.key")
        self.identity = try Self.loadOrCreateIdentity(at: identityURL)

        // 清理旧版本遗留的交换私钥文件（前向保密后不再使用；缩小落盘密钥面）。
        // best-effort：删不掉（权限等）不报错，不阻塞 store 初始化。
        let legacyExchange = dir.appendingPathComponent("exchange.key")
        try? fm.removeItem(at: legacyExchange)
    }

    private static func loadOrCreateIdentity(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        // 显式两步：文件存在则**不吞错**地读，读/解析失败即 throw，绝不覆盖旧密钥。
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw DevKeyStoreError.unreadableKeyFile(url.path) }
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw DevKeyStoreError.corruptedKeyFile(url.path)
            }
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try writeSecret(key.rawRepresentation, to: url)
        return key
    }

    private static func loadOrCreateExchange(at url: URL) throws -> Curve25519.KeyAgreement.PrivateKey {
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw DevKeyStoreError.unreadableKeyFile(url.path) }
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                throw DevKeyStoreError.corruptedKeyFile(url.path)
            }
            return key
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
