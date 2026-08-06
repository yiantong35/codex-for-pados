import SwiftUI
import Observation

/// appearance-locale：运行时语言切换 + 深浅色主题。
/// 两个 @Observable manager 在 App 根用 @State 创建并 .environment 注入，
/// SettingsMenu 用 @Environment 读取/修改。持久化用注入式 UserDefaults（默认 .standard，
/// 测试可注入独立 suite 隔离）。

// MARK: - 语言

enum AppLanguage: String, CaseIterable {
    case system   // 跟随系统（与外观 AppTheme.system 对齐），放首位 = UI 首项
    case zh
    case en

    /// SwiftUI 环境 locale 注入用的标识。zh 走简体中文资源。
    /// `.system` 动态解析系统首选语言：以 "zh" 开头→简体中文，其余→英文。
    /// `preferredLanguages` 参数化以便单测（默认取 `Locale.preferredLanguages`，避免 flaky）。
    func localeIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system:
            let first = preferredLanguages.first ?? "en"
            return first.hasPrefix("zh") ? "zh-Hans" : "en"
        case .zh: return "zh-Hans"
        case .en: return "en"
        }
    }

    /// 无参入口：转调参数化版本，兼容既有调用点。
    var localeIdentifier: String { localeIdentifier() }
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
            self.language = .system   // 默认跟随系统
        }
    }

    var locale: Locale { Locale(identifier: language.localeIdentifier()) }

    /// D5：无 SwiftUI 环境可读的层（Store）从持久化 app_language 解析当前 locale，
    /// 与根视图 `.environment(\.locale, locale)` 注入同源。不用 `String(localized:)`（按系统语言选表）。
    static var currentLocale: Locale {
        let raw = UserDefaults.standard.string(forKey: key)
        let lang = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        return Locale(identifier: lang.localeIdentifier())
    }
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

    /// sheet 专用：把 `.system` 解析成一个**具体**的 ColorScheme（由外部宿主传入真实系统值），
    /// 而非返回 nil。原因：`.preferredColorScheme(nil)` 施加在 sheet 上时**不会**重置之前
    /// 已强制的深/浅色（SwiftUI 把 nil 当「未表态」而非「回到系统」），导致深色→跟随系统时
    /// sheet 卡在深色（里黑外白）。传入具体值可彻底规避该问题。
    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        colorScheme ?? system
    }
}

// MARK: - 剪贴板写门控（#1 安全）

/// 远端终端 OSC 52 写系统剪贴板的门控开关。默认关闭（fail-closed）。
/// 持久化键 "clipboard_allow_remote_write"；单次写入上限 64KB（超限拒写、不截断）。
@Observable
final class ClipboardPolicyStore {
    private let store: UserDefaults
    private static let key = "clipboard_allow_remote_write"
    /// 单次写入字节上限：正常终端复制的命令/路径/代码远小于此。
    static let maxWriteBytes = 64 * 1024

    var allowRemoteWrite: Bool {
        didSet { store.set(allowRemoteWrite, forKey: Self.key) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        self.allowRemoteWrite = store.bool(forKey: Self.key)   // 缺省 false = 默认关闭
    }

    /// 是否允许本次写入：开关开 且 未超上限。
    func shouldWrite(byteCount: Int) -> Bool {
        allowRemoteWrite && byteCount <= Self.maxWriteBytes
    }
}
