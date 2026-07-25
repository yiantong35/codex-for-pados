import Foundation

/// 稳定 sessionId 持久化抽象。
///
/// stableSessionId 是 dev 在首配握手第 4 条 SecureReady 里回传的「撮合标签」——iPad 消费后
/// 持久化，后续复连直接用它作 relay 房间号免再走一次性 pairingCode（受信任复连）。
/// **它不是机密**（只是路由标签，真正的信任由双向验签 + TOFU 保证），故生产实现用 UserDefaults。
protocol StableSessionStoring: Sendable {
    /// 取某机器已持久化的 stableSessionId；未配对过返回 nil。
    func stableSessionId(machineKey: String) -> String?
    /// 存/覆盖某机器的 stableSessionId。
    func save(machineKey: String, stableSessionId: String)
}

/// 生产实现：UserDefaults。stableSessionId 非机密（撮合标签），无需 Keychain。
/// `suiteName` 可注入便于测试隔离；nil 时用 `.standard`。
final class UserDefaultsStableSessionStore: StableSessionStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    private func key(_ machineKey: String) -> String { "relay-stable-\(machineKey)" }

    func stableSessionId(machineKey: String) -> String? {
        defaults.string(forKey: key(machineKey))
    }

    func save(machineKey: String, stableSessionId: String) {
        defaults.set(stableSessionId, forKey: key(machineKey))
    }
}
