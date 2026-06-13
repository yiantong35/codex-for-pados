import Foundation
import Security

/// 凭证安全存储：用 Security framework 的 Keychain（generic password）持久化敏感项
/// （SSH 私钥 PEM / 密码）。非敏感连接项（主机/端口/用户）由调用方存 `UserDefaults`。
///
/// 可访问性固定为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：
/// 仅设备解锁后可读，且不随 iCloud Keychain / 备份迁移到其它设备。
struct KeychainStore {
    let service: String

    enum KeychainError: Error { case os(OSStatus) }

    /// 写入（覆盖式）：先删旧项再添加，避免 `errSecDuplicateItem`。
    func save(_ value: String, for account: String) throws {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
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
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw KeychainError.os(status) }
        return String(data: d, encoding: .utf8)
    }

    /// 删除；不存在视为成功（幂等）。
    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.os(status) }
    }
}
