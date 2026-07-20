import Foundation
import SwiftUI
import Observation

/// 改键结果（设计 D3）。
enum RebindResult: Equatable {
    case accepted
    case rejected(RebindRejection)
}

/// 改键被拒原因（设计 D3）。
enum RebindRejection: Equatable {
    case occupied(by: ShortcutAction)  // 已被另一 app 内动作占用
    case systemReserved                // 命中系统保留键黑名单
}

/// 快捷键注册中心（设计 D1/D3）：动作 → 键位单一数据源。
/// 覆盖优先否则默认；覆盖持久化到 UserDefaults（仿 SidebarCollapseStore 模式）。
@Observable
@MainActor
final class ShortcutStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "shortcuts.overrides"

    /// 动作 rawValue → 用户覆盖 KeyCombo。
    private var overrides: [String: KeyCombo]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "shortcuts.overrides"),
           let map = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            overrides = map
        } else {
            overrides = [:]
        }
    }

    /// 当前键位：覆盖优先否则默认（设计 D1）。
    func combo(for action: ShortcutAction) -> KeyCombo {
        overrides[action.rawValue] ?? action.defaultCombo
    }

    /// 是否已被用户改过（设置页判断能否「恢复默认」）。
    func isOverridden(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// 改键校验管线（设计 D3）：Task 5 补全冲突检测，本任务先直写以让持久化测试通过。
    @discardableResult
    func rebind(_ action: ShortcutAction, to target: KeyCombo) -> RebindResult {
        overrides[action.rawValue] = target
        persist()
        return .accepted
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
