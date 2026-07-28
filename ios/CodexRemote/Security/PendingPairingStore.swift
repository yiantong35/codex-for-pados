import Foundation

/// pending 配对凭据（一次性 pairingCode）仅驻内存、不落任何盘。
/// 配对是一次连续前台操作；未完成 app 被杀 → 重新扫码。绝不写 UserDefaults/Keychain。
@MainActor
final class PendingPairingStore {
    static let shared = PendingPairingStore()
    private var codes: [UUID: String] = [:]
    func stash(_ code: String, for machineId: UUID) { codes[machineId] = code }
    /// 非破坏性读取：建连前用 peek 拿 pc，失败可重试不必重扫（握手成功前不消费）。
    func peek(for machineId: UUID) -> String? { codes[machineId] }
    /// 一次性取出（取出即删）：收到 SecureReady（握手成功）后消费；对已删键返回 nil 幂等。
    func take(for machineId: UUID) -> String? { codes.removeValue(forKey: machineId) }
}
