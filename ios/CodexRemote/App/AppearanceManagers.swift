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

// MARK: - 文字大小（global-text-scaling）

/// 全局文字缩放档位（6 档命名阶梯，模型/选择器/快捷键共用）。
/// rawValue 兼作持久化值，**只追加不改名**（改名会丢已存 app_text_scale）。
/// `.system` 首位 = 默认（跟随系统，不注入覆盖）；其余五档携带非 nil DynamicTypeSize。
enum AppTextScale: String, CaseIterable, Identifiable {
    case system        // 跟随系统（默认，不注入覆盖）
    case small         // 小（覆盖档下限）
    case medium        // 中
    case large         // 大
    case extraLarge    // 特大
    case accessibility // 辅助功能（覆盖档上限）

    var id: String { rawValue }

    /// 映射到原生 DynamicTypeSize；`.system` → nil（根视图条件不注入 = 放行系统 Dynamic Type）。
    var overrideSize: DynamicTypeSize? {
        switch self {
        case .system:        return nil
        case .small:         return .small
        case .medium:        return .medium
        case .large:         return .xLarge
        case .extraLarge:    return .xxxLarge
        case .accessibility: return .accessibility3
        }
    }

    /// 覆盖档有序阶梯（不含 `.system`）：放大/缩小沿此移动一档并钳制两端。
    static let overrideLadder: [AppTextScale] = [.small, .medium, .large, .extraLarge, .accessibility]

    /// 从 base 沿阶梯移动 delta 档并钳制（下界 `.small`、上界 `.accessibility`）。
    /// base 若非阶梯档（如 `.system`）兜底取下限索引 0——视图层保证只传阶梯档，此为防御。
    static func stepped(from base: AppTextScale, by delta: Int) -> AppTextScale {
        let idx = overrideLadder.firstIndex(of: base) ?? 0
        let clamped = min(max(idx + delta, 0), overrideLadder.count - 1)
        return overrideLadder[clamped]
    }

    /// U1：把当前有效 DynamicTypeSize 映射到最近覆盖档（用作「跟随系统」下放大/缩小的基线）。
    /// 取阶梯中原生值 `<= size` 的最大档；比下限还小取 `.small`、超上限取 `.accessibility`。
    /// DynamicTypeSize 符合 Comparable，可直接比较。
    static func nearestOverride(for size: DynamicTypeSize) -> AppTextScale {
        var result: AppTextScale = .small
        for scale in overrideLadder {
            if let native = scale.overrideSize, native <= size { result = scale }
        }
        return result
    }
}

/// 文字大小管理器：持久化 "app_text_scale"，映射到 `DynamicTypeSize?`（nil = 跟随系统）。默认跟随系统。
/// 根视图用条件注入（见 AppDynamicTypeSizeModifier）；快捷键分发经 baseline/increase/decrease/reset。
@Observable
final class TextScaleManager {
    private let store: UserDefaults
    private static let key = "app_text_scale"

    var scale: AppTextScale {
        didSet { store.set(scale.rawValue, forKey: Self.key) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        if let raw = store.string(forKey: Self.key), let s = AppTextScale(rawValue: raw) {
            self.scale = s
        } else {
            self.scale = .system   // 默认跟随系统
        }
    }

    /// 当前应注入的覆盖档（`.system` → nil = 不注入）。
    var overrideSize: DynamicTypeSize? { scale.overrideSize }

    /// U1 基线：跟随系统时把视图捕获的有效档映射为覆盖档基线，否则即当前档。
    func baseline(effective: DynamicTypeSize) -> AppTextScale {
        scale == .system ? AppTextScale.nearestOverride(for: effective) : scale
    }

    func increase(baseline: AppTextScale) { scale = AppTextScale.stepped(from: baseline, by: 1) }
    func decrease(baseline: AppTextScale) { scale = AppTextScale.stepped(from: baseline, by: -1) }
    func reset() { scale = .system }
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
