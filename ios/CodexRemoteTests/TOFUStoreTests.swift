import XCTest
@testable import CodexRemote

final class TOFUStoreTests: XCTestCase {

    /// 首次即信任：无记录 → 存下，不抛错。
    func testFirstUseTrustsAndRemembers() throws {
        let store = InMemoryTOFUStore()
        let pub = Data([1, 2, 3, 4])
        try store.verifyOrTrust(machineKey: "m1", presentedPub: pub)
        XCTAssertEqual(store.rememberedIdentity(forMachineKey: "m1"), pub)
    }

    /// 再连一致：记录 == 出示 → 通过。
    func testSecondUseSamePubPasses() throws {
        let store = InMemoryTOFUStore()
        let pub = Data([9, 9, 9])
        try store.verifyOrTrust(machineKey: "m1", presentedPub: pub)
        XCTAssertNoThrow(try store.verifyOrTrust(machineKey: "m1", presentedPub: pub))
    }

    /// 身份变更：记录 != 出示 → 抛 identityChanged（防中间人换开发机身份）。
    func testChangedPubRejected() throws {
        let store = InMemoryTOFUStore()
        try store.verifyOrTrust(machineKey: "m1", presentedPub: Data([1, 1, 1]))
        XCTAssertThrowsError(try store.verifyOrTrust(machineKey: "m1", presentedPub: Data([2, 2, 2]))) {
            XCTAssertEqual($0 as? TOFUError, .identityChanged)
        }
    }

    /// 不同机器键互不干扰（一 relay 连接一 TOFU 记录）。
    func testDifferentMachineKeysIsolated() throws {
        let store = InMemoryTOFUStore()
        try store.verifyOrTrust(machineKey: "m1", presentedPub: Data([1]))
        XCTAssertNoThrow(try store.verifyOrTrust(machineKey: "m2", presentedPub: Data([2])))
    }

    /// 首信持久化失败必须 fail-closed：写失败即上抛底层错误，不得静默当成功。
    /// 否则下次连接又当"首信"，会重新信任对端出示的任意公钥，MITM 检测静默失效。
    func testFirstUseFailsClosedWhenPersistFails() {
        let store = FailingWriteTOFUStore()
        XCTAssertThrowsError(try store.verifyOrTrust(machineKey: "m1", presentedPub: Data([1, 2, 3]))) { err in
            XCTAssertFalse(err is TOFUError, "写入失败不应被误判为 identityChanged，而应上抛底层写错误")
            XCTAssertTrue(err is FailingWriteTOFUStore.WriteError, "应上抛持久化层的原始写错误")
        }
    }
}

/// 写入必失败的替身，验证首信 fail-closed。
private final class FailingWriteTOFUStore: TOFUStoring, @unchecked Sendable {
    struct WriteError: Error {}
    func rememberedIdentity(forMachineKey key: String) -> Data? { nil }
    func remember(_ identityPub: Data, forMachineKey key: String) throws { throw WriteError() }
}
