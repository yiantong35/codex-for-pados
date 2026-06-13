import SwiftUI
import Observation

/// appearance-locale：运行时语言切换 + 深浅色主题。
/// 两个 @Observable manager 在 App 根用 @State 创建并 .environment 注入，
/// SettingsMenu 用 @Environment 读取/修改。持久化用注入式 UserDefaults（默认 .standard，
/// 测试可注入独立 suite 隔离）。

// MARK: - 语言

enum AppLanguage: String, CaseIterable {
    case zh
    case en

    /// SwiftUI 环境 locale 注入用的标识。zh 走简体中文资源。
    var localeIdentifier: String {
        switch self {
        case .zh: return "zh-Hans"
        case .en: return "en"
        }
    }
}

/// 语言管理器：持久化 "app_language"，暴露当前 locale。默认中文。
/// 运行时切换：根视图把 `locale` 经 `.environment(\.locale, ...)` 注入，
/// 所有 `Text(LocalizedStringKey)` 随之刷新。
@Observable
final class LocaleManager {
    private let store: UserDefaults
    private static let key = "app_language"

    var language: AppLanguage {
        didSet { store.set(language.rawValue, forKey: Self.key) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        if let raw = store.string(forKey: Self.key), let lang = AppLanguage(rawValue: raw) {
            self.language = lang
        } else {
            self.language = .zh   // 默认中文
        }
    }

    var locale: Locale { Locale(identifier: language.localeIdentifier) }
}

// MARK: - 主题

enum AppTheme: String, CaseIterable {
    case system
    case light
    case dark
}

/// 主题管理器：持久化 "app_theme"，映射到 `ColorScheme?`（nil = 跟随系统）。默认跟随系统。
/// 根视图用 `.preferredColorScheme(themeManager.colorScheme)`。
@Observable
final class ThemeManager {
    private let store: UserDefaults
    private static let key = "app_theme"

    var theme: AppTheme {
        didSet { store.set(theme.rawValue, forKey: Self.key) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        if let raw = store.string(forKey: Self.key), let t = AppTheme(rawValue: raw) {
            self.theme = t
        } else {
            self.theme = .system   // 默认跟随系统
        }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
