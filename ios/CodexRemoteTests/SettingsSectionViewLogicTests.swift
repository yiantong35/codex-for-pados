import XCTest
import SwiftUI
@testable import CodexRemote

/// 分区视图的纯逻辑单测（选择切换 + 当前值标识），用注入式 UserDefaults 隔离。
@MainActor
final class SettingsSectionViewLogicTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsSectionViewLogicTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAppearanceSelectSwitchesThemeAndPersists() {
        let theme = ThemeManager(store: defaults)
        XCTAssertEqual(theme.theme, .system)
        theme.theme = .dark
        XCTAssertEqual(theme.theme, .dark)
        XCTAssertEqual(theme.colorScheme, .dark)
        XCTAssertEqual(ThemeManager(store: defaults).theme, .dark)
    }

    func testAppearanceCurrentSelectionMarker() {
        let theme = ThemeManager(store: defaults)
        theme.theme = .light
        for t in AppTheme.allCases {
            XCTAssertEqual(theme.theme == t, t == .light)
        }
    }
}
