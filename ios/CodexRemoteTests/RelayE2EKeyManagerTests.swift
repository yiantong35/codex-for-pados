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

private final class ReadFailingKeyStore: KeyStoring {
    struct ReadFailed: Error {}
    private(set) var saveCount = 0
    func saveKey(_ value: Data) { saveCount += 1 }
    func saveKeyThrowing(_ value: Data) throws { saveCount += 1 }
    func loadKey() throws -> Data? { throw ReadFailed() }
    func deleteKey() {}
}

private final class CorruptedKeyStore: KeyStoring {
    private(set) var saveCount = 0
    func saveKey(_ value: Data) { saveCount += 1 }
    func saveKeyThrowing(_ value: Data) throws { saveCount += 1 }
    func loadKey() throws -> Data? { Data([0x01]) }
    func deleteKey() {}
}

/// 保存必失败的 store：验证 identityKey() 落盘失败时抛错、不缓存。
private struct ThrowingKeyStore: KeyStoring {
    struct WriteFailed: Error {}
    func saveKey(_ value: Data) {}                    // 默认实现不该被 identityKey 走到
    func saveKeyThrowing(_ value: Data) throws { throw WriteFailed() }
    func loadKey() -> Data? { nil }
    func deleteKey() {}
}

/// 底层 keychain 写失败的替身：`saveKeyThrowing` 恒抛（模拟 keychain 写盘失败）。
/// 用于锁死 relay 身份落盘 fail-closed —— 写失败必须继续 throw、绝不回退为吞掉的 fail-open。
private struct FailingKeychainStore: KeyStoring {
    struct WriteFailed: Error {}
    func saveKey(_ value: Data) {}
    func saveKeyThrowing(_ value: Data) throws { throw WriteFailed() }
    func loadKey() -> Data? { nil }
    func deleteKey() {}
}

@MainActor
final class RelayE2EKeyManagerTests: XCTestCase {

    /// 身份密钥幂等：同一 store 下两个 manager 拿到同一身份公钥（重启不丢身份）。
    func testIdentityKeyIsPersistentAndIdempotent() throws {
        let store = MemoryKeyStore()
        let m1 = RelayE2EKeyManager(store: store)
        let pub1 = try m1.identityKey().publicKey.rawRepresentation
        let m2 = RelayE2EKeyManager(store: store)   // 从同一 store 重建
        let pub2 = try m2.identityKey().publicKey.rawRepresentation
        XCTAssertEqual(pub1, pub2, "身份密钥应持久幂等复用")
    }

    /// Keychain 写失败 → identityKey() 抛错、不缓存该密钥、配对以失败告终而非静默成功。
    func testIdentityKeyThrowsAndDoesNotCacheOnSaveFailure() {
        let m = RelayE2EKeyManager(store: ThrowingKeyStore())
        XCTAssertThrowsError(try m.identityKey())         // 落盘失败必抛
        XCTAssertThrowsError(try m.identityKey())         // 未缓存 → 再次仍抛（不会返回上次的“成功”密钥）
    }

    func testIdentityReadFailureDoesNotGenerateOrOverwriteIdentity() {
        let store = ReadFailingKeyStore()
        let manager = RelayE2EKeyManager(store: store)

        XCTAssertThrowsError(try manager.identityKey()) { error in
            XCTAssertTrue(error is ReadFailingKeyStore.ReadFailed)
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testCorruptedIdentityDoesNotGenerateOrOverwriteIdentity() {
        let store = CorruptedKeyStore()
        let manager = RelayE2EKeyManager(store: store)

        XCTAssertThrowsError(try manager.identityKey()) { error in
            XCTAssertEqual(error as? RelayE2EKeychainStore.ReadError, .recordCorrupted)
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testMalformedBase64IdentityRecordFailsClosed() throws {
        let service = "com.codexremote.test.e2e-corrupt-\(UUID())"
        let keychain = KeychainStore(service: service)
        let account = "relay-e2e-identity-ed25519"
        defer { try? keychain.delete(account) }
        try keychain.save("not-base64!", for: account)

        XCTAssertThrowsError(try RelayE2EKeyManager(
            store: RelayE2EKeychainStore(keychain: keychain)
        ).identityKey()) { error in
            XCTAssertEqual(error as? RelayE2EKeychainStore.ReadError, .recordCorrupted)
        }
        XCTAssertEqual(try keychain.load(account), "not-base64!")
    }

    /// 底层 keychain 写盘失败时，relay 身份落盘路径（`saveKeyThrowing`）必须继续 throw、绝不吞掉。
    /// 锁死 relay 身份持久化 fail-closed，防未来回归为 fail-open（静默成功但实际未落盘）。
    /// 经真实注入 seam `RelayE2EKeyManager(store:)` → `identityKey()` → `store.saveKeyThrowing` 验证。
    func test_relayIdentity_saveKeyThrowing_propagatesWriteFailure() {
        let failing = FailingKeychainStore()             // saveKeyThrowing 恒抛（模拟 keychain 写盘失败）
        let m = RelayE2EKeyManager(store: failing)
        XCTAssertThrowsError(try m.identityKey()) { error in
            XCTAssertTrue(error is FailingKeychainStore.WriteFailed,
                          "写失败应原样传播、不被吞掉为 fail-open")
        }
    }

    /// 落盘成功 → 缓存并幂等复用（重启从同一 store 重建拿同一身份）。
    func testIdentityKeyCachesAfterSuccessfulSave() throws {
        let store = MemoryKeyStore()
        let m1 = RelayE2EKeyManager(store: store)
        let pub1 = try m1.identityKey().publicKey.rawRepresentation
        let pub2 = try RelayE2EKeyManager(store: store).identityKey().publicKey.rawRepresentation
        XCTAssertEqual(pub1, pub2)
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
        _ = try m.identityKey()

        let sshRaw = try XCTUnwrap(try keychain.load("ssh-ed25519-private-key"))
        XCTAssertEqual(Data(base64Encoded: sshRaw), Data("ssh-secret".utf8), "E2E 不得覆盖 SSH account")
        XCTAssertNotNil(try keychain.load("relay-e2e-identity-ed25519"), "E2E account 应独立写入")

        try? keychain.delete("ssh-ed25519-private-key")
        try? keychain.delete("relay-e2e-identity-ed25519")
    }
}
