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
}
