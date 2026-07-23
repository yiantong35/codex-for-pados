import Foundation
@testable import CodexRemote

/// 测试用内存 TOFU 存储（可跨测试文件复用，供握手/集成测注入）。
final class InMemoryTOFUStore: TOFUStoring, @unchecked Sendable {
    private var map: [String: Data] = [:]
    private let lock = NSLock()
    func rememberedIdentity(forMachineKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func remember(_ identityPub: Data, forMachineKey key: String) {
        lock.lock(); map[key] = identityPub; lock.unlock()
    }
}
