import Foundation

/// 连接密钥的存储抽象：生产实现走 Keychain，测试可注入内存替身。
/// 仅存私钥 rawRepresentation（32 字节）的二进制，不做格式约定。
protocol KeyStoring {
    func saveKey(_ value: Data)
    /// 可抛版本：默认转调 saveKey（SSH 侧零改动、不抛）。需要真实反馈写失败的实现（relay）可 override。
    func saveKeyThrowing(_ value: Data) throws
    func loadKey() -> Data?
    func deleteKey()
}

extension KeyStoring {
    /// 默认实现：SSH（KeychainKeyStore）沿用旧的静默保存语义，不抛。
    func saveKeyThrowing(_ value: Data) throws { saveKey(value) }
}
