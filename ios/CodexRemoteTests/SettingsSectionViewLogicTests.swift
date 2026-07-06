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

    // MARK: - 语言（Task 4）

    func testLanguageSelectSwitchesLocaleAndPersists() {
        let locale = LocaleManager(store: defaults)
        XCTAssertEqual(locale.language, .zh)
        locale.language = .en
        XCTAssertEqual(locale.language, .en)
        XCTAssertEqual(locale.locale.identifier, "en")
        XCTAssertEqual(LocaleManager(store: defaults).language, .en)
    }

    func testLanguageCurrentSelectionMarker() {
        let locale = LocaleManager(store: defaults)
        locale.language = .zh
        for l in AppLanguage.allCases {
            XCTAssertEqual(locale.language == l, l == .zh)
        }
    }

    // MARK: - 账户（Task 5）：展示态映射纯逻辑

    func testAccountRowsForChatgpt() {
        let rows = AccountInfoView.rows(
            account: .chatgpt(email: "a@b.com", planType: "plus"),
            usage: AccountTokenUsageSummary(lifetimeTokens: 1000, peakDailyTokens: nil,
                                            longestRunningTurnSec: nil, currentStreakDays: nil,
                                            longestStreakDays: nil),
            rateLimits: RateLimitSnapshot(limitId: "codex", limitName: nil,
                                          primary: RateLimitWindow(usedPercent: 42, windowDurationMins: nil, resetsAt: nil),
                                          secondary: nil))
        XCTAssertTrue(rows.contains(.email("a@b.com")))
        XCTAssertTrue(rows.contains(.plan("plus")))
        XCTAssertTrue(rows.contains(.lifetime("1000")))
        XCTAssertTrue(rows.contains(.rateUsed("42%")))
    }

    func testAccountRowsApiKey() {
        let rows = AccountInfoView.rows(account: .apiKey, usage: nil, rateLimits: nil)
        XCTAssertTrue(rows.contains(.kind("API Key")))
    }

    func testAccountRowsEmptyWhenNil() {
        XCTAssertTrue(AccountInfoView.rows(account: nil, usage: nil, rateLimits: nil).isEmpty)
    }

    /// 混合态：账户未到（nil）但用量已到——必须显示"未登录"身份行，避免只见用量不知归属。
    func testAccountRowsNilAccountWithUsageShowsNotSignedIn() {
        let rows = AccountInfoView.rows(
            account: nil,
            usage: AccountTokenUsageSummary(lifetimeTokens: 1000, peakDailyTokens: nil,
                                            longestRunningTurnSec: nil, currentStreakDays: nil,
                                            longestStreakDays: nil),
            rateLimits: nil)
        XCTAssertTrue(rows.contains(.notSignedIn))
        XCTAssertTrue(rows.contains(.lifetime("1000")))
    }

    /// 全空态不变：account/usage/rateLimits 全 nil → rows 为空（走 settings.account.empty 空态）。
    func testAccountRowsAllNilStaysEmpty() {
        XCTAssertTrue(AccountInfoView.rows(account: nil, usage: nil, rateLimits: nil).isEmpty)
    }
}
