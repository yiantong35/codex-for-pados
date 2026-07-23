import XCTest
import Crypto
@testable import CodexRemote

/// 复用内存 KeyStoring 替身（不碰 Keychain），验证身份持久幂等 + 交换密钥每次新生成。
private final class MemoryKeyStore: KeyStoring {
    private var data: Data?
    func saveKey(_ value: Data) { data = value }
    func loadKey() -> Data? { data }
    func deleteKey() { data = nil }
}

@MainActor
final class RelayE2EKeyManagerTests: XCTestCase {

    /// 身份密钥幂等：同一 store 下两个 manager 拿到同一身份公钥（重启不丢身份）。
    func testIdentityKeyIsPersistentAndIdempotent() {
        let store = MemoryKeyStore()
        let m1 = RelayE2EKeyManager(store: store)
        let pub1 = m1.identityKey().publicKey.rawRepresentation
        let m2 = RelayE2EKeyManager(store: store)   // 从同一 store 重建
        let pub2 = m2.identityKey().publicKey.rawRepresentation
        XCTAssertEqual(pub1, pub2, "身份密钥应持久幂等复用")
    }

    /// 交换密钥每次新生成（前向保密），不持久。
    func testEphemeralKeyIsFreshEachCall() {
        let m = RelayE2EKeyManager(store: MemoryKeyStore())
        let e1 = m.newEphemeralKey().publicKey.rawRepresentation
        let e2 = m.newEphemeralKey().publicKey.rawRepresentation
        XCTAssertNotEqual(e1, e2, "交换密钥每次应新生成")
    }

    /// 与 SSH 密钥 account 隔离：同一 KeychainStore service 下，E2E account 与 SSH account 互不覆盖。
    func testE2EAccountIsolatedFromSSHAccount() throws {
        let keychain = KeychainStore(service: "com.codexremote.test.iso")
        try? keychain.delete("ssh-ed25519-private-key")
        try? keychain.delete("relay-e2e-identity-ed25519")

        // SSH 侧写一把（模拟 KeyManager 的存法）。
        try keychain.save(Data("ssh-secret".utf8).base64EncodedString(), for: "ssh-ed25519-private-key")
        // E2E 侧生成身份。
        let m = RelayE2EKeyManager(store: RelayE2EKeychainStore(keychain: keychain))
        _ = m.identityKey()

        let sshRaw = try XCTUnwrap(try keychain.load("ssh-ed25519-private-key"))
        XCTAssertEqual(Data(base64Encoded: sshRaw), Data("ssh-secret".utf8), "E2E 不得覆盖 SSH account")
        XCTAssertNotNil(try keychain.load("relay-e2e-identity-ed25519"), "E2E account 应独立写入")

        try? keychain.delete("ssh-ed25519-private-key")
        try? keychain.delete("relay-e2e-identity-ed25519")
    }
}
