import Foundation

/// pending 配对凭据（一次性 pairingCode）仅驻内存、不落任何盘。
/// 配对是一次连续前台操作；未完成 app 被杀 → 重新扫码。绝不写 UserDefaults/Keychain。
@MainActor
final class PendingPairingStore {
    static let shared = PendingPairingStore()
    private var codes: [UUID: String] = [:]
    func stash(_ code: String, for machineId: UUID) { codes[machineId] = code }
    /// 一次性取出（取出即删）：首配连接用一次后即释放。
    func take(for machineId: UUID) -> String? { codes.removeValue(forKey: machineId) }
}
