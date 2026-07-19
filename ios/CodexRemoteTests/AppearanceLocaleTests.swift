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
}
