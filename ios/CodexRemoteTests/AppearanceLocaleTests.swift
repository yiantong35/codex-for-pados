import XCTest
import SwiftUI
@testable import CodexRemote

/// appearance-locale：LocaleManager / ThemeManager 的默认值、持久化、映射纯逻辑单测。
/// 用独立 UserDefaults suite 隔离，避免污染 standard。
@MainActor
final class AppearanceLocaleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppearanceLocaleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - LocaleManager

    // Task 5.4：默认从 .zh 改为 .system（首次跟随系统，与外观 AppTheme.system 对齐）。
    func testLanguageDefaultsToSystem() {
        let m = LocaleManager(store: defaults)
        XCTAssertEqual(m.language, .system)
    }

    func testSwitchToEnglishPersistsAndReadsBack() {
        LocaleManager(store: defaults).language = .en
        // 新实例从同一 store 读取，应保持英文
        let reloaded = LocaleManager(store: defaults)
        XCTAssertEqual(reloaded.language, .en)
        XCTAssertEqual(reloaded.locale.identifier, "en")
    }

    func testSwitchBackToChinese() {
        let m = LocaleManager(store: defaults)
        m.language = .en
        m.language = .zh
        XCTAssertEqual(m.language, .zh)
        XCTAssertEqual(LocaleManager(store: defaults).language, .zh)
    }

    // MARK: - Task 5.4：.system 动态解析系统首选语言

    func testSystemResolvesChineseWhenPreferredChinese() {
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["zh-CN"]), "zh-Hans")
    }

    func testSystemResolvesEnglishWhenPreferredEnglish() {
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["en-US"]), "en")
    }

    func testSystemFallsBackToEnglishForOtherLanguages() {
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: ["fr"]), "en")
    }

    func testSystemFallsBackToEnglishWhenEmptyPreferred() {
        XCTAssertEqual(AppLanguage.system.localeIdentifier(preferredLanguages: []), "en")
    }

    func testExplicitLanguagesIgnorePreferred() {
        // 显式 zh/en 不受系统首选影响。
        XCTAssertEqual(AppLanguage.zh.localeIdentifier(preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.en.localeIdentifier(preferredLanguages: ["zh-CN"]), "en")
    }

    // MARK: - ThemeManager

    func testThemeDefaultsToSystem() {
        let m = ThemeManager(store: defaults)
        XCTAssertEqual(m.theme, .system)
        XCTAssertNil(m.colorScheme)
    }

    func testThemeColorSchemeMapping() {
        let m = ThemeManager(store: defaults)
        m.theme = .light
        XCTAssertEqual(m.colorScheme, .light)
        m.theme = .dark
        XCTAssertEqual(m.colorScheme, .dark)
        m.theme = .system
        XCTAssertNil(m.colorScheme)
    }

    func testThemePersistsAndReadsBack() {
        ThemeManager(store: defaults).theme = .dark
        let reloaded = ThemeManager(store: defaults)
        XCTAssertEqual(reloaded.theme, .dark)
        XCTAssertEqual(reloaded.colorScheme, .dark)
    }

    // MARK: - Task 10 / OpenSpec 4.4：首次安装外观/语言默认跟随系统（回归护栏）

    /// 全新 UserDefaults suite（模拟首次安装、无任何已存偏好），与 setUp 的实例无关，
    /// 每个 case 独立构造 → 断言首启即 .system，且已选值在“重启”后不被 .system 覆盖。
    private func freshInstallDefaults() -> UserDefaults {
        let name = "AppearanceDefaults.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_freshInstallLanguageDefaultsToSystem() {
        XCTAssertEqual(LocaleManager(store: freshInstallDefaults()).language, .system)
    }

    func test_freshInstallThemeDefaultsToSystem() {
        XCTAssertEqual(ThemeManager(store: freshInstallDefaults()).theme, .system)
    }

    func test_storedLanguageValueIsRestored() {
        let d = freshInstallDefaults()
        LocaleManager(store: d).language = .en          // 存一个非默认值
        let reopened = LocaleManager(store: d)          // 重启模拟
        XCTAssertEqual(reopened.language, .en)          // 已选值应保留，不被 .system 覆盖
    }

    func test_storedThemeValueIsRestored() {
        let d = freshInstallDefaults()
        ThemeManager(store: d).theme = .dark
        let reopened = ThemeManager(store: d)
        XCTAssertEqual(reopened.theme, .dark)
    }

    // MARK: - 真机回归：文字缩放注入的结构恒定性（Bug 2/3 根因护栏）

    /// AppDynamicTypeSizeModifier 必须结构恒定注入 range：
    /// 跟随系统(nil) → 全范围（等价不钳制），覆盖档 → 单档钳定。
    /// 若回归成「nil 不注入 / 某单档」，选档会重建子树 → 关闭设置 sheet、丢失即时生效。
    func test_dynamicTypeClampRange_systemIsFullRange() {
        XCTAssertEqual(AppDynamicTypeSizeModifier.clampRange(for: nil),
                       DynamicTypeSize.xSmall ... DynamicTypeSize.accessibility5,
                       "跟随系统必须映射为全范围（放行系统 Dynamic Type），而非某单档")
    }

    func test_dynamicTypeClampRange_overrideClampsToSingleSize() {
        for scale in AppTextScale.allCases where scale != .system {
            guard let size = scale.overrideSize else {
                XCTFail("非 system 档 \(scale.rawValue) 应有非 nil overrideSize"); continue
            }
            XCTAssertEqual(AppDynamicTypeSizeModifier.clampRange(for: size), size...size,
                           "覆盖档 \(scale.rawValue) 应钳定到单档")
        }
    }

    /// system 档必须映射为 nil（不注入具体档），其余档非 nil。
    func test_textScaleOverrideSizeMapping() {
        XCTAssertNil(AppTextScale.system.overrideSize)
        for scale in AppTextScale.allCases where scale != .system {
            XCTAssertNotNil(scale.overrideSize, "档 \(scale.rawValue) 应有非 nil overrideSize")
        }
    }

    // MARK: - 用户诉求回归：四档偏小阶梯 + 选择器不含跟随系统 + 移除辅助功能/特大

    /// 选择器只展示四个具体档位，且**不含** `.system`（默认未选择即跟随系统，无此选项）。
    /// 顺序固定：大 → 标准 → 小 → 更小。
    func test_selectableCases_excludesSystemAndIsFourTiers() {
        XCTAssertEqual(AppTextScale.selectableCases, [.xLarge, .large, .medium, .small])
        XCTAssertFalse(AppTextScale.selectableCases.contains(.system), "选择器不得含跟随系统")
        XCTAssertEqual(AppTextScale.selectableCases.count, 4)
    }

    /// 档位以系统默认 `.large` 为锚：large=系统默认、medium/small 严格更小、xLarge 略大。
    /// 修「最小档和跟随系统没差」：small(.small) 明确低于系统默认 .large（往下两档）。
    func test_ladderAnchoredAtSystemDefaultLarge() {
        XCTAssertEqual(AppTextScale.large.overrideSize, .large, "标准档应等于系统默认 .large")
        XCTAssertEqual(AppTextScale.xLarge.overrideSize, .xLarge)
        XCTAssertEqual(AppTextScale.medium.overrideSize, .medium)
        XCTAssertEqual(AppTextScale.small.overrideSize, .small)
        // 两个「更小」档严格小于系统默认。
        XCTAssertLessThan(AppTextScale.medium.overrideSize!, DynamicTypeSize.large)
        XCTAssertLessThan(AppTextScale.small.overrideSize!, DynamicTypeSize.large)
        XCTAssertLessThan(AppTextScale.small.overrideSize!, AppTextScale.medium.overrideSize!)
    }

    /// overrideLadder 升序、且为四个具体档（快捷键放大/缩小沿此移动）。
    func test_overrideLadderIsAscendingConcrete() {
        XCTAssertEqual(AppTextScale.overrideLadder, [.small, .medium, .large, .xLarge])
        let sizes = AppTextScale.overrideLadder.compactMap { $0.overrideSize }
        XCTAssertEqual(sizes.count, 4)
        XCTAssertEqual(sizes, sizes.sorted(), "阶梯应按原生字号升序")
    }

    /// 移除的档位（辅助功能/特大）不得再解码为有效档——旧持久化值回落 nil（→ 跟随系统）。
    func test_removedTiersNoLongerDecode() {
        XCTAssertNil(AppTextScale(rawValue: "accessibility"), "辅助功能档应已移除")
        XCTAssertNil(AppTextScale(rawValue: "extraLarge"), "特大档应已移除")
    }
}
