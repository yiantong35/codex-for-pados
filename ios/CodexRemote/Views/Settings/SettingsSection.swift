import SwiftUI

/// 设置页分区（ipad-settings-page 设计 D2 / ipad-extensions-panel D1）：纯数据枚举，驱动左导航 List 与右 detail switch。
/// `extensions` 分区以分组长列表承载 MCP / Skills / Plugins 三组。默认选中 .account。
enum SettingsSection: String, CaseIterable, Identifiable {
    case account
    case appearance
    case language
    case extensions
    case shortcuts

    /// NavigationSplitView 的 List(selection:) 需要 Identifiable。
    var id: SettingsSection { self }

    /// 首次打开设置页默认选中的分区。
    static let `default`: SettingsSection = .account

    /// 左导航行标题（本地化 key，值见 Localizable.xcstrings）。
    var label: LocalizedStringKey {
        switch self {
        case .account:    return "settings.account"
        case .appearance: return "settings.appearance"
        case .language:   return "settings.language"
        case .extensions: return "settings.extensions"
        case .shortcuts:  return "settings.shortcuts"
        }
    }

    /// 左导航行图标（SF Symbol）。
    var icon: String {
        switch self {
        case .account:    return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .language:   return "globe"
        case .extensions: return "puzzlepiece.extension.fill"
        case .shortcuts:  return "keyboard"
        }
    }
}
