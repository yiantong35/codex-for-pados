import Testing
import Foundation
@testable import CodexRemote

/// 测试用内存 SSH host key 存储（可注入，验证 TOFU 语义，不触真 Keychain）。
private final class MemoryHostKeyStore: SSHHostKeyStoring, @unchecked Sendable {
    private var map: [String: Data] = [:]
    private let lock = NSLock()
    func rememberedHostKey(forMachineKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func remember(_ hostKey: Data, forMachineKey key: String) throws {
        lock.lock(); map[key] = hostKey; lock.unlock()
    }
}

@Test func hostKeyFirstUseTrustsAndPersists() throws {
    let s = MemoryHostKeyStore()
    let k = Data([1, 2, 3])
    try s.verifyOrTrust(machineKey: "m", presentedHostKey: k)   // 首次：存下并信任
    #expect(s.rememberedHostKey(forMachineKey: "m") == k)
    try s.verifyOrTrust(machineKey: "m", presentedHostKey: k)   // 再连：比对通过，不抛
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
    #expect(store.rememberedHostKey(forMachineKey: "mac1") == k)
    // 独立性：SSH host key 用独立 service（默认 com.codexremote.ssh-hostkey），
    // 与 relay 侧 relay-tofu-* / E2E 密钥天然隔离，互不复用同一 Keychain 记录。
}
