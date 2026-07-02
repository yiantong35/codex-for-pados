import Foundation
import Crypto
import Observation

/// 连接密钥的存储抽象：生产实现走 Keychain，测试可注入内存替身。
/// 仅存私钥 rawRepresentation（32 字节）的二进制，不做格式约定。
protocol KeyStoring {
    func saveKey(_ value: Data)
    func loadKey() -> Data?
    func deleteKey()
}

/// KeychainStore 适配为 KeyStoring：把 32 字节私钥 base64 后当 String 存。
/// 失败时静默（生成/读取路径已通过 hasKey/Optional 表达可观察状态）。
struct KeychainKeyStore: KeyStoring {
    let keychain: KeychainStore
    /// 与连接密码项区分的独立 account。
    let account = "ssh-ed25519-private-key"

    func saveKey(_ value: Data) {
        try? keychain.save(value.base64EncodedString(), for: account)
    }
    func loadKey() -> Data? {
        guard let s = (try? keychain.load(account)) ?? nil, let d = Data(base64Encoded: s) else { return nil }
        return d
    }
    func deleteKey() {
        try? keychain.delete(account)
    }
}

/// 连接密钥管理：app 内生成一次 ed25519 密钥对、自动复用、对外暴露 OpenSSH 公钥与指纹。
///
/// 设计取舍：
/// - 私钥用 CryptoKit `Curve25519.Signing.PrivateKey`，可直传 Citadel `.ed25519(username:privateKey:)`，无需 PEM。
/// - 存储只持久化 rawRepresentation（32 字节），公钥/指纹按需从私钥推导，避免存冗余且永远一致。
/// - `@Observable` 让 SwiftUI 在生成/重新生成后自动反映 `hasKey`。
@Observable @MainActor
final class KeyManager {
    private let store: KeyStoring
    /// 当前私钥的内存缓存；nil 表示尚未加载或不存在。
    private var cachedKey: Curve25519.Signing.PrivateKey?

    init(store: KeyStoring) {
        self.store = store
        // 启动即尝试从存储重建，驱动 hasKey 的自动检测。
        if let raw = store.loadKey(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            cachedKey = key
        }
    }

    /// 便利构造：生产环境用真 Keychain。
    convenience init(service: String = "com.codexremote.ssh") {
        self.init(store: KeychainKeyStore(keychain: KeychainStore(service: service)))
    }

    /// 是否已有连接密钥。
    var hasKey: Bool { cachedKey != nil }

    /// 若无密钥则生成并持久化；已有则不动（幂等，自动复用的核心）。
    func generateIfNeeded() {
        guard cachedKey == nil else { return }
        store(newKey: Curve25519.Signing.PrivateKey())
    }

    /// 强制生成新密钥替换旧的（UI 层会加二次确认）。旧公钥随即失效。
    func regenerate() {
        store(newKey: Curve25519.Signing.PrivateKey())
    }

    /// 供建连使用的 CryptoKit 私钥；无则 nil。
    func privateKey() -> Curve25519.Signing.PrivateKey? { cachedKey }

    /// OpenSSH 格式公钥：`ssh-ed25519 <base64(wire)> codexremote@ipad`。
    func publicKeyOpenSSH() -> String? {
        guard let blob = wireBlob() else { return nil }
        return "ssh-ed25519 " + blob.base64EncodedString() + " codexremote@ipad"
    }

    /// OpenSSH 风格指纹：`SHA256:<base64-no-padding(SHA256(wireBlob))>`。
    func fingerprintSHA256() -> String? {
        guard let blob = wireBlob() else { return nil }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    // MARK: - 私有

    private func store(newKey key: Curve25519.Signing.PrivateKey) {
        store.saveKey(key.rawRepresentation)
        cachedKey = key
    }

    /// 公钥 wire blob：sshString("ssh-ed25519") + sshString(publicKey.rawRepresentation)。
    private func wireBlob() -> Data? {
        guard let key = cachedKey else { return nil }
        var blob = Data()
        blob.append(Self.sshString("ssh-ed25519".data(using: .utf8)!))
        blob.append(Self.sshString(key.publicKey.rawRepresentation))
        return blob
    }

    /// SSH 字符串编码：4 字节大端长度前缀 + 字节。
    private static func sshString(_ bytes: Data) -> Data {
        var out = Data()
        var len = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }
}
