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

/// 全局文字缩放档位。默认状态是 `.system`（跟随系统，不注入覆盖，且**不在选择器里出现**）；
/// 用户在设置里手动选四个具体档位之一后才写入并持久化（此后不再自动回落跟随系统）。
/// rawValue 兼作持久化值，**只追加不改名**（改名会丢已存 app_text_scale）。
/// 四个可选档位以系统默认档 `.large` 为锚：上 1 档（大 .xLarge）、系统默认（标准 .large）、
/// 下 2 档（小 .medium、更小 .small）。用户诉求＝主要往小、去掉辅助功能/特大等放大档。
enum AppTextScale: String, CaseIterable, Identifiable {
    case system   // 跟随系统（默认/未选择态，不注入覆盖，**不在选择器出现**）
    case small    // 更小（比系统默认小 2 档）
    case medium   // 小（比系统默认小 1 档）
    case large    // 标准（= 系统默认档 .large）
    case xLarge   // 大（比系统默认大 1 档）
    case xxLarge  // 更大（比系统默认大 2 档；text-scale-extra-large，持久化 append-only 兼容）

    var id: String { rawValue }

    /// 映射到原生 DynamicTypeSize；`.system` → nil（不注入 = 放行系统 Dynamic Type）。
    /// 锚在系统默认 `.large`：`large` 即系统默认，`medium`/`small` 明确更小，`xLarge`/`xxLarge` 递进更大。
    var overrideSize: DynamicTypeSize? {
        switch self {
        case .system:  return nil
        case .small:   return .small
        case .medium:  return .medium
        case .large:   return .large
        case .xLarge:  return .xLarge
        case .xxLarge: return .xxLarge
        }
    }

    /// 设置选择器展示的档位（不含 `.system`）。顺序：更大 → 大 → 标准 → 小 → 更小（自上而下渐小）。
    static let selectableCases: [AppTextScale] = [.xxLarge, .xLarge, .large, .medium, .small]

    /// 覆盖档有序阶梯（不含 `.system`，升序）：放大/缩小沿此移动一档并钳制两端。
    static let overrideLadder: [AppTextScale] = [.small, .medium, .large, .xLarge, .xxLarge]

    /// 从 base 沿阶梯移动 delta 档并钳制（下界 `.small`、上界 `.xxLarge`）。
    /// base 若非阶梯档（如 `.system`）兜底取下限索引 0——视图层保证只传阶梯档，此为防御。
    static func stepped(from base: AppTextScale, by delta: Int) -> AppTextScale {
        let idx = overrideLadder.firstIndex(of: base) ?? 0
        let clamped = min(max(idx + delta, 0), overrideLadder.count - 1)
        return overrideLadder[clamped]
    }

    /// U1：把当前有效 DynamicTypeSize 映射到最近覆盖档（用作「跟随系统」下放大/缩小的基线）。
    /// 取阶梯中原生值 `<= size` 的最大档；比下限还小取 `.small`、超上限取 `.xxLarge`。
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

/// 根注入用修饰：把文字缩放档映射为 `.dynamicTypeSize` 的**范围**恒定注入。
///
/// 关键（修真机回归）：**必须结构恒定**——绝不能用 `if size != nil { content.dynamicTypeSize(x) } else { content }`
/// 这种按 size 有无返回不同视图结构的写法。那样从「跟随系统」(nil) 切到覆盖档时，SwiftUI 判定
/// 视图 identity 变化 → **重建整棵 RootView 子树**，连带 dismiss 正在呈现的设置 sheet、丢失导航与 @State
/// （用户表现为「选完档位设置页直接被关掉、也看不到即时生效」）。
///
/// 用 range 版 `dynamicTypeSize(_:)` 恒定注入即可两全：
/// - 覆盖档 → `size...size`：钳定到该档（等价旧的单值注入）。
/// - 跟随系统 → `.xSmall ... .accessibility5`：全范围 = 不实际钳制，系统 Dynamic Type 原样放行
///   （规避 `.dynamicTypeSize(nil)` 的「未表态」陷阱，也不改变视图结构）。
/// 结构恒定后 size 变化只更新参数、不重建子树 → sheet 保持呈现、环境即时刷新。
struct AppDynamicTypeSizeModifier: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        // 结构恒定：无论 size 有无，都只调用一次 `.dynamicTypeSize(range)`，
        // 不用 if/else 返回不同视图结构（否则切档重建子树 → 关 sheet、丢 @State）。
        content.dynamicTypeSize(Self.clampRange(for: size))
    }

    /// 把覆盖档映射为 `dynamicTypeSize(_:)` 的范围：
    /// - 覆盖档 → `size...size`（钳定到该档）
    /// - 跟随系统(nil) → 全范围 `.xSmall ... .accessibility5`（不实际钳制，放行系统 Dynamic Type）
    /// 提为静态纯函数以便单测（回归护栏：nil 必须映射为全范围而非某单档）。
    static func clampRange(for size: DynamicTypeSize?) -> ClosedRange<DynamicTypeSize> {
        if let size { return size...size }
        return .xSmall ... .accessibility5
    }
}

// MARK: - 分组设置 List 抗闪修复（问题2 真因收口）

extension View {
    /// 消除深色下设置分组 box「黑底→灰底」首帧闪烁。
    ///
    /// 真因（CADisplayLink 逐帧取证：15 帧 trait 恒为 Dark/Base、box 恒为 28,28,30 灰、
    /// page 恒为 0,0,0 黑，颜色/trait 全程不变）：闪烁**不是** colorScheme/level 重解析，而是
    /// `List`(.insetGrouped) 底层 UITableView 的 grouped cell 填充由 UIKit 在 `willDisplayCell`/
    /// 布局阶段晚一个 runloop 才 blit——首帧纯黑 page(systemGroupedBackground) 从 box 区域透出（黑），
    /// 下一帧 table 才绘上灰色 cell 填充（灰）。故 #110（窗口深色）/#111（fullScreenCover base level）
    /// 都在改错误维度、治不好。
    ///
    /// 修法：用 `listRowBackground` 把 box 填充改由 SwiftUI 随行内容在**同一渲染事务**合成，
    /// 首帧即 present，不再依赖 UITableView 的晚绘制路径 → 结构上不可能出现黑首帧。
    /// 色值仍取语义色 `secondarySystemGroupedBackground`，深浅自适应不变。
    func settingsGroupedRowBackground() -> some View {
        listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
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
