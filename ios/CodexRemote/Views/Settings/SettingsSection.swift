import SwiftUI

/// 设置页分区（ipad-settings-page 设计 D2）：纯数据枚举，驱动左导航 List 与右 detail switch。
/// 后续 MCP/插件/skills = 加 case + switch 分支，零架构改动。默认选中 .account。
enum SettingsSection: String, CaseIterable, Identifiable {
    case account
    case appearance
    case language
    case mcp

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
        case .mcp:        return "settings.mcp"
        }
    }

    /// 左导航行图标（SF Symbol）。
    var icon: String {
        switch self {
        case .account:    return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .language:   return "globe"
        case .mcp:        return "puzzlepiece.extension"
        }
    }
}
