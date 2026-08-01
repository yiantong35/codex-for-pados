import Foundation
import Crypto
import Observation

/// E2E 身份密钥的 Keychain 适配：独立 account，与 SSH（`ssh-ed25519-private-key`）严格分离。
/// 复用 KeyManager.swift 定义的 `KeyStoring` 协议（同 target，internal 可见）。
struct RelayE2EKeychainStore: KeyStoring {
    let keychain: KeychainStore
    /// 与 SSH account 严格分离，绝不覆盖。
    let account = "relay-e2e-identity-ed25519"

    func saveKey(_ value: Data) {
        try? keychain.save(value.base64EncodedString(), for: account)
    }
    /// #5：relay 身份写 Keychain 真实抛错（不吞），供 identityKey() 落盘确认。
    func saveKeyThrowing(_ value: Data) throws {
        try keychain.save(value.base64EncodedString(), for: account)
    }
    func loadKey() -> Data? {
        guard let s = (try? keychain.load(account)) ?? nil, let d = Data(base64Encoded: s) else { return nil }
        return d
    }
    func deleteKey() { try? keychain.delete(account) }
}

/// iPad 侧 relay E2E 密钥管理：镜像 `KeyManager` 模式（`KeyStoring` + 可注入 store + `@Observable`），
/// 但独立类、独立 Keychain service/account。
/// - Ed25519 身份密钥（`Curve25519.Signing`）：持久化、幂等复用（重启不丢身份 —— TOFU 稳定前提）。
/// - X25519 交换密钥（`Curve25519.KeyAgreement`）：每次连接新生成，不持久（前向保密）。
/// - **不改** `KeyManager`（专管 SSH `Curve25519.Signing`），职责分离防误用同一把密钥。
@Observable @MainActor
final class RelayE2EKeyManager {
    private let store: KeyStoring
    private var cachedIdentity: Curve25519.Signing.PrivateKey?

    init(store: KeyStoring) {
        self.store = store
        if let raw = store.loadKey(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            cachedIdentity = key
        }
    }

    /// 生产：独立 service，与 SSH 的 `com.codexremote.ssh` 分离。
    convenience init(service: String = "com.codexremote.relay-e2e") {
        self.init(store: RelayE2EKeychainStore(keychain: KeychainStore(service: service)))
    }

    /// 身份私钥：无则生成并**确认持久化成功后**才缓存复用（幂等）。落盘失败抛错、不缓存、不参与配对。
    @discardableResult
    func identityKey() throws -> Curve25519.Signing.PrivateKey {
        if let k = cachedIdentity { return k }
        let k = Curve25519.Signing.PrivateKey()
        try store.saveKeyThrowing(k.rawRepresentation)   // 落盘失败 → 抛出，cachedIdentity 保持 nil
        cachedIdentity = k
        return k
    }

    /// 身份公钥 raw（供 ClientHello）。
    func identityPublicKeyRaw() throws -> Data { try identityKey().publicKey.rawRepresentation }

    /// 每会话新生成的 X25519 交换私钥（前向保密，不持久）。供 KeySchedule 派生。
    func newEphemeralKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }
}
