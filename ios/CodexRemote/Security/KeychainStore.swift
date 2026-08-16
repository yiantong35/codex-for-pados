import Foundation
import Security

protocol KeychainAccessing: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SecurityKeychainAccess: KeychainAccessing {
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

/// 凭证安全存储：用 Security framework 的 Keychain（generic password）持久化敏感项
/// （SSH 私钥 PEM / 密码）。非敏感连接项（主机/端口/用户）由调用方存 `UserDefaults`。
///
/// 可访问性固定为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：
/// 仅设备解锁后可读，且不随 iCloud Keychain / 备份迁移到其它设备。
struct KeychainStore {
    let service: String
    private let access: any KeychainAccessing

    init(service: String, access: any KeychainAccessing = SecurityKeychainAccess()) {
        self.service = service
        self.access = access
    }

    enum KeychainError: Error { case os(OSStatus) }

    /// Update an existing record in place. A missing record is the only condition that permits add.
    /// Thus an update failure cannot destroy the previous identity or TOFU value.
    func save(_ value: String, for account: String) throws {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updateStatus = access.update(query as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.os(updateStatus) }

        var add = query
        for (key, value) in values { add[key] = value }
        let addStatus = access.add(add as CFDictionary)
        guard addStatus == errSecSuccess else { throw KeychainError.os(addStatus) }
    }

    /// 读取；不存在返回 nil，其它 OSStatus 异常抛 `KeychainError.os`。
    func load(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = access.copyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw KeychainError.os(status) }
        guard let value = String(data: d, encoding: .utf8) else {
            throw KeychainError.os(errSecDecode)
        }
        return value
    }

    /// 删除；不存在视为成功（幂等）。
    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        let status = access.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.os(status) }
    }
}
