import Testing
import Foundation
import Security
import Crypto
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import CodexRemote

/// 测试用内存 SSH host key 存储（可注入，验证 TOFU 语义，不触真 Keychain）。
private final class MemoryHostKeyStore: SSHHostKeyStoring, @unchecked Sendable {
    private var map: [String: Data] = [:]
    private let lock = NSLock()
    func rememberedHostKey(forMachineKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func remember(_ hostKey: Data, forMachineKey key: String) throws {
        lock.lock(); map[key] = hostKey; lock.unlock()
    }
}

/// 对抗性 mock：读取信任锚时抛"notFound 以外"的 Keychain 错误（模拟锁屏窗口期
/// `errSecInteractionNotAllowed` / `errSecAuthFailed` / 瞬时故障）。用于验证读失败必须
/// fail-closed（拒连），且绝不覆盖信任锚（不调 remember）。
private final class ReadFailingHostKeyStore: SSHHostKeyStoring, @unchecked Sendable {
    let readError: Error
    private(set) var rememberCalled = false
    init(readError: Error) { self.readError = readError }
    func rememberedHostKey(forMachineKey key: String) throws -> Data? { throw readError }
    func remember(_ hostKey: Data, forMachineKey key: String) throws { rememberCalled = true }
}

/// 造一个真 ed25519 `NIOSSHPublicKey`（走公开 `init(openSSHPublicKey:)`），
/// 用于把 host key 喂进 `TOFUHostKeyDelegate.validateHostKey`，验证 promise succeed/fail。
private func makeHostKey() -> NIOSSHPublicKey {
    let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    // SSH 线格式 blob：string("ssh-ed25519") + string(32B 公钥)，再 base64 → "ssh-ed25519 <b64>"。
    func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count).bigEndian
        return withUnsafeBytes(of: n) { Array($0) } + bytes
    }
    let blob = sshString(Array("ssh-ed25519".utf8)) + sshString(Array(pub))
    let openSSH = "ssh-ed25519 \(Data(blob).base64EncodedString())"
    return try! NIOSSHPublicKey(openSSHPublicKey: openSSH)
}

struct SSHHostKeyStoreTests {

    // MARK: - 2.2 store 语义 + Keychain 往返

    @Test func hostKeyFirstUseTrustsAndPersists() throws {
        let s = MemoryHostKeyStore()
        let k = Data([1, 2, 3])
        try s.verifyOrTrust(machineKey: "m", presentedHostKey: k)   // 首次：存下并信任
        #expect(try s.rememberedHostKey(forMachineKey: "m") == k)
        try s.verifyOrTrust(machineKey: "m", presentedHostKey: k)   // 再连：比对通过，不抛
    }

    /// 读信任锚遇 notFound 以外错误（锁屏窗口期等）：verifyOrTrust 必须抛错拒连（fail-closed），
    /// 且绝不把读失败当首信 → 绝不调 remember 覆盖信任锚。旧代码用 `try?` 吞错→当首信→调 remember，
    /// 此断言在旧代码下失败。
    @Test func hostKeyReadFailureFailsClosedWithoutOverwriting() throws {
        let store = ReadFailingHostKeyStore(
            readError: KeychainStore.KeychainError.os(errSecInteractionNotAllowed))
        #expect(throws: (any Error).self) {
            try store.verifyOrTrust(machineKey: "m", presentedHostKey: Data([1, 2, 3]))
        }
        #expect(store.rememberCalled == false)   // 读失败绝不覆盖/污染信任锚
    }

    @Test func hostKeyChangeFailsClosed() throws {
        let s = MemoryHostKeyStore()
        try s.verifyOrTrust(machineKey: "m", presentedHostKey: Data([1]))
        #expect(throws: SSHHostKeyError.hostKeyChanged) {
            try s.verifyOrTrust(machineKey: "m", presentedHostKey: Data([9]))   // 变更 → fail-closed
        }
    }

    @Test func keychainHostKeyStoreRoundTripsIndependentOfRelayTOFU() throws {
        let service = "com.codexremote.ssh-hostkey.test-\(UUID())"
        let store = KeychainSSHHostKeyStore(service: service)
        defer { try? KeychainStore(service: service).delete("ssh-hostkey-mac1") }
        let k = Data([4, 5, 6])
        try store.remember(k, forMachineKey: "mac1")
        #expect(try store.rememberedHostKey(forMachineKey: "mac1") == k)
        // 独立性：SSH host key 用独立 service（默认 com.codexremote.ssh-hostkey），
        // 与 relay 侧 relay-tofu-* / E2E 密钥天然隔离，互不复用同一 Keychain 记录。
    }

    // MARK: - 2.3 host key 决策逻辑（从 NIO 回调抽出便于测）

    @Test func decisionTrustsFirstThenRejectsChange() throws {
        let s = MemoryHostKeyStore()
        try SSHHostKeyDecision.decide(store: s, machineKey: "m", hostKeyBytes: Data([1]))   // 首次 OK，存下
        try SSHHostKeyDecision.decide(store: s, machineKey: "m", hostKeyBytes: Data([1]))   // 再连 OK
        #expect(throws: SSHHostKeyError.hostKeyChanged) {
            try SSHHostKeyDecision.decide(store: s, machineKey: "m", hostKeyBytes: Data([2]))   // 变更 → 拒
        }
    }

    // MARK: - 2.4 端到端语义：真 NIOSSHPublicKey 驱动 delegate promise（首信 succeed / 变更 fail-closed）

    @Test func delegateSucceedsFirstUseAndPersists() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let store = MemoryHostKeyStore()
        let delegate = TOFUHostKeyDelegate(store: store, machineKey: "m")
        let key = makeHostKey()

        // 首次：delegate 应 succeed（首信），且 store 落下该 host key。
        let p1 = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: key, validationCompletePromise: p1)
        #expect(throws: Never.self) { try p1.futureResult.wait() }
        #expect(try store.rememberedHostKey(forMachineKey: "m") != nil)

        // 再连同一 host key：仍 succeed（比对通过）。
        let p2 = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: key, validationCompletePromise: p2)
        #expect(throws: Never.self) { try p2.futureResult.wait() }
    }

    @Test func delegateFailsClosedOnHostKeyChange() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let store = MemoryHostKeyStore()
        let delegate = TOFUHostKeyDelegate(store: store, machineKey: "m")

        // 首次信任 keyA。
        let p1 = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: makeHostKey(), validationCompletePromise: p1)
        #expect(throws: Never.self) { try p1.futureResult.wait() }

        // 换一把 host key（模拟 host key 变更 / MITM）：delegate 必须 fail-closed（promise fail）。
        // promise fail = SSH 握手中断，不进入 initialize。
        let p2 = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: makeHostKey(), validationCompletePromise: p2)
        #expect(throws: SSHHostKeyError.hostKeyChanged) { try p2.futureResult.wait() }
    }
}
