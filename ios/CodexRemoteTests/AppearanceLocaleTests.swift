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

    func testLanguageDefaultsToChinese() {
        let m = LocaleManager(store: defaults)
        XCTAssertEqual(m.language, .zh)
        XCTAssertEqual(m.locale.identifier, "zh-Hans")
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
