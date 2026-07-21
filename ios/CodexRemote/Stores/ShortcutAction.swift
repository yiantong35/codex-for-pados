import SwiftUI

/// 快捷键作用域（设计 D1）。
enum ShortcutScope: String {
    case global      // 全局（tab 切换、添加机器）
    case workspace   // 主界面（面板开合、右栏跳转）
    case form        // 表单（Esc 取消）
}

/// 可绑定动作全集（设计 D1）：穷举 22 个动作，编译期保证不漏绑。
/// rawValue 兼作 UserDefaults 覆盖表的 key，不可随意改名（会丢已存覆盖）。
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Tab（global）
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
    case nextTab, prevTab, addMachine
    // 面板（workspace）
    case toggleLeftPanel, toggleRightPanel, toggleBottomPanel, toggleSummary, openSettings
    // 右栏（workspace）
    case rightPanelReview, rightPanelFiles, rightPanelSideChat, rightPanelFullscreen
    // 表单（form，固定）
    case cancelForm

    var id: String { rawValue }

    /// 固定动作（Esc 取消）不可改键，其余皆可（设计 D1）。
    var isCustomizable: Bool { self != .cancelForm }

    var scope: ShortcutScope {
        switch self {
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9,
             .nextTab, .prevTab, .addMachine:
            return .global
        case .toggleLeftPanel, .toggleRightPanel, .toggleBottomPanel, .toggleSummary, .openSettings,
             .rightPanelReview, .rightPanelFiles, .rightPanelSideChat, .rightPanelFullscreen:
            return .workspace
        case .cancelForm:
            return .form
        }
    }

    /// 默认键位（proposal v2 清单，设计 D1）。
    var defaultCombo: KeyCombo {
        switch self {
        case .tab1: return KeyCombo(key: "1", modifiers: .command)
        case .tab2: return KeyCombo(key: "2", modifiers: .command)
        case .tab3: return KeyCombo(key: "3", modifiers: .command)
        case .tab4: return KeyCombo(key: "4", modifiers: .command)
        case .tab5: return KeyCombo(key: "5", modifiers: .command)
        case .tab6: return KeyCombo(key: "6", modifiers: .command)
        case .tab7: return KeyCombo(key: "7", modifiers: .command)
        case .tab8: return KeyCombo(key: "8", modifiers: .command)
        case .tab9: return KeyCombo(key: "9", modifiers: .command)
        case .nextTab: return KeyCombo(key: "]", modifiers: .command)
        case .prevTab: return KeyCombo(key: "[", modifiers: .command)
        case .addMachine: return KeyCombo(key: "t", modifiers: .command)
        case .toggleLeftPanel: return KeyCombo(key: "b", modifiers: .command)
        case .toggleRightPanel: return KeyCombo(key: "b", modifiers: [.command, .shift])
        case .toggleBottomPanel: return KeyCombo(key: "j", modifiers: .command)
        case .toggleSummary: return KeyCombo(key: "i", modifiers: .command)
        case .openSettings: return KeyCombo(key: ",", modifiers: .command)
        case .rightPanelReview: return KeyCombo(key: "d", modifiers: [.command, .shift])
        case .rightPanelFiles: return KeyCombo(key: "f", modifiers: [.command, .shift])
        case .rightPanelSideChat: return KeyCombo(key: "c", modifiers: [.command, .shift])
        case .rightPanelFullscreen: return KeyCombo(key: "f", modifiers: [.command, .control])
        case .cancelForm: return KeyCombo(key: KeyCombo.escapeKey, modifiers: [])
        }
    }

    /// 本地化标题 key（值见 Localizable.xcstrings，Task 13 补齐）。
    var titleKey: LocalizedStringKey { LocalizedStringKey("shortcut.action.\(rawValue)") }

    /// 供设置页显式取 String（分组排序/无障碍用）。
    var titleStringKey: String { "shortcut.action.\(rawValue)" }
}
