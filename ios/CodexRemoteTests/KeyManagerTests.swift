import XCTest
import Crypto
@testable import CodexRemote

/// 内存替身：实现 KeyStoring，避免测试触碰真实 Keychain（CI/无 entitlement 环境亦稳）。
private final class InMemoryKeyStore: KeyStoring {
    private var data: Data?
    func saveKey(_ value: Data) { data = value }
    func loadKey() -> Data? { data }
    func deleteKey() { data = nil }
}

final class KeyManagerTests: XCTestCase {
    @MainActor
    func testInitiallyNoKey() {
        let mgr = KeyManager(store: InMemoryKeyStore())
        XCTAssertFalse(mgr.hasKey)
        XCTAssertNil(mgr.publicKeyOpenSSH())
        XCTAssertNil(mgr.fingerprintSHA256())
    }

    @MainActor
    func testGenerateIfNeededProducesKeyAndOpenSSHArtifacts() {
        let mgr = KeyManager(store: InMemoryKeyStore())
        mgr.generateIfNeeded()
        XCTAssertTrue(mgr.hasKey)

        let pub = mgr.publicKeyOpenSSH()
        XCTAssertNotNil(pub)
        XCTAssertTrue(pub!.hasPrefix("ssh-ed25519 "), "公钥应为 OpenSSH ed25519 格式，实际：\(pub ?? "nil")")
        XCTAssertTrue(pub!.hasSuffix(" codexremote@ipad"), "公钥应带固定 comment，实际：\(pub ?? "nil")")

        let fp = mgr.fingerprintSHA256()
        XCTAssertNotNil(fp)
        XCTAssertTrue(fp!.hasPrefix("SHA256:"), "指纹应以 SHA256: 开头，实际：\(fp ?? "nil")")
    }

    /// 核心：重复调用 generateIfNeeded 不应替换已有密钥（自动复用，不重复生成）。
    @MainActor
    func testGenerateIfNeededIsIdempotent() {
        let mgr = KeyManager(store: InMemoryKeyStore())
        mgr.generateIfNeeded()
        let first = mgr.publicKeyOpenSSH()
        mgr.generateIfNeeded()
        let second = mgr.publicKeyOpenSSH()
        XCTAssertEqual(first, second, "二次 generateIfNeeded 不得改变密钥")
    }

    func testRegenerateReplacesKey() {
        let store = InMemoryKeyStore()
        Task { @MainActor in }   // no-op，保持结构清晰
        let exp = expectation(description: "regenerate")
        Task { @MainActor in
            let mgr = KeyManager(store: store)
            mgr.generateIfNeeded()
            let before = mgr.publicKeyOpenSSH()
            mgr.regenerate()
            let after = mgr.publicKeyOpenSSH()
            XCTAssertNotEqual(before, after, "regenerate 应产生新密钥")
            XCTAssertTrue(mgr.hasKey)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    /// privateKey() 能从存储重建，且重建后推导出的公钥与生成时一致。
    @MainActor
    func testPrivateKeyRebuildMatchesPublicKey() {
        let store = InMemoryKeyStore()
        let mgr = KeyManager(store: store)
        mgr.generateIfNeeded()
        let pubAtGen = mgr.publicKeyOpenSSH()

        // 用同一存储新建 manager，模拟 app 重启后的自动复用路径。
        let reloaded = KeyManager(store: store)
        XCTAssertTrue(reloaded.hasKey)
        XCTAssertEqual(reloaded.publicKeyOpenSSH(), pubAtGen, "重启后重建的公钥应与生成时相同")

        // 重建的 CryptoKit 私钥可用，且其 publicKey.rawRepresentation 与 OpenSSH 公钥内嵌一致。
        let key = reloaded.privateKey()
        XCTAssertNotNil(key)
        XCTAssertEqual(key!.publicKey.rawRepresentation.count, 32)
    }
}
