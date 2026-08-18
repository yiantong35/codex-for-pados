import XCTest
import SwiftUI
@testable import CodexRemote

/// TextScaleManager / AppTextScale 的默认值、持久化、6 档钳制、U1 基线映射纯逻辑单测。
/// 独立 UserDefaults suite 隔离，避免污染 standard。
@MainActor
final class TextScaleManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TextScaleManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // 默认跟随系统（首次安装，无持久化值）。
    func testDefaultsToSystem() {
        XCTAssertEqual(TextScaleManager(store: defaults).scale, .system)
        XCTAssertNil(TextScaleManager(store: defaults).overrideSize)
    }

    // 6 档命名阶梯 → 原生 DynamicTypeSize 映射。
    func testOverrideSizeMapping() {
        XCTAssertNil(AppTextScale.system.overrideSize)
        XCTAssertEqual(AppTextScale.small.overrideSize, .small)
        XCTAssertEqual(AppTextScale.medium.overrideSize, .medium)
        XCTAssertEqual(AppTextScale.large.overrideSize, .xLarge)
        XCTAssertEqual(AppTextScale.extraLarge.overrideSize, .xxxLarge)
        XCTAssertEqual(AppTextScale.accessibility.overrideSize, .accessibility3)
        XCTAssertEqual(AppTextScale.allCases.count, 6)
    }

    // 覆盖档持久化跨重启。
    func testOverridePersistsAcrossRestart() {
        TextScaleManager(store: defaults).scale = .large
        XCTAssertEqual(TextScaleManager(store: defaults).scale, .large)
    }

    // 放大沿阶梯并钳制上界（辅助功能）。
    func testSteppedClampsUpper() {
        XCTAssertEqual(AppTextScale.stepped(from: .medium, by: 1), .large)
        XCTAssertEqual(AppTextScale.stepped(from: .accessibility, by: 1), .accessibility)
    }

    // 缩小沿阶梯并钳制下界（小）。
    func testSteppedClampsLower() {
        XCTAssertEqual(AppTextScale.stepped(from: .medium, by: -1), .small)
        XCTAssertEqual(AppTextScale.stepped(from: .small, by: -1), .small)
    }

    // reset 回跟随系统。
    func testResetReturnsToSystem() {
        let m = TextScaleManager(store: defaults)
        m.scale = .accessibility
        m.reset()
        XCTAssertEqual(m.scale, .system)
    }

    // U1：跟随系统下以有效系统档映射到最近覆盖档作基线。
    func testNearestOverrideBaseline() {
        XCTAssertEqual(AppTextScale.nearestOverride(for: .medium), .medium)
        // 比下限还小 → 钳到 .small。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .xSmall), .small)
        // 超上限 → 钳到 .accessibility。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .accessibility5), .accessibility)
        // .large 档原生是 .xLarge：有效 .xLarge 应映射到 .large 而非更高。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .xLarge), .large)
    }

    // 根注入契约：overrideSize 为 nil 即「跟随系统」= 不注入（禁止 .dynamicTypeSize(nil)）。
    func testSystemYieldsNilOverrideForConditionalInjection() {
        let m = TextScaleManager(store: defaults)
        XCTAssertNil(m.overrideSize)          // .system → nil → modifier 走「不注入」分支
        m.scale = .accessibility
        XCTAssertEqual(m.overrideSize, .accessibility3)  // 覆盖档 → 注入具体值
    }

    // increase/decrease 用视图传入的基线驱动模型。
    func testIncreaseDecreaseFromBaseline() {
        let m = TextScaleManager(store: defaults)
        m.increase(baseline: .medium)
        XCTAssertEqual(m.scale, .large)
        m.decrease(baseline: m.scale)
        XCTAssertEqual(m.scale, .medium)
    }
}
