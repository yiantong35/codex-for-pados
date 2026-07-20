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

    /// 改键校验管线（设计 D3，硬阻）：先查系统黑名单，再查 app 内部占用；
    /// 命中任一即拒绝、不写入、原绑定不变；通过才持久化。
    @discardableResult
    func rebind(_ action: ShortcutAction, to target: KeyCombo) -> RebindResult {
        guard action.isCustomizable else { return .rejected(.systemReserved) } // 固定动作防御性拒绝
        if SystemReservedShortcuts.all.contains(target) {
            return .rejected(.systemReserved)
        }
        if let occupant = occupant(of: target, excluding: action) {
            return .rejected(.occupied(by: occupant))
        }
        overrides[action.rawValue] = target
        persist()
        return .accepted
    }

    /// 找出当前占用 target 的其它可绑定动作（对比覆盖后的实际键位）。
    private func occupant(of target: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && other.isCustomizable && combo(for: other) == target
        }
    }

    /// 单动作恢复默认。
    func resetToDefault(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
        persist()
    }

    /// 全部恢复默认。
    func resetAll() {
        overrides.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
