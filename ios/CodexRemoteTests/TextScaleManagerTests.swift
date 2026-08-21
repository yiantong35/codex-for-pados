import XCTest
import SwiftUI
@testable import CodexRemote

/// TextScaleManager / AppTextScale 的默认值、持久化、四档钳制、U1 基线映射纯逻辑单测。
/// 独立 UserDefaults suite 隔离，避免污染 standard。
/// 档位以系统默认 `.large` 为锚：xLarge(大) / large(标准) / medium(小) / small(更小)，
/// system(跟随系统) 为默认未选择态、不在选择器出现。
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

    // 四档命名阶梯 → 原生 DynamicTypeSize 映射（+ system 共 5 个 case）。
    func testOverrideSizeMapping() {
        XCTAssertNil(AppTextScale.system.overrideSize)
        XCTAssertEqual(AppTextScale.small.overrideSize, .small)
        XCTAssertEqual(AppTextScale.medium.overrideSize, .medium)
        XCTAssertEqual(AppTextScale.large.overrideSize, .large)   // 标准 = 系统默认
        XCTAssertEqual(AppTextScale.xLarge.overrideSize, .xLarge) // 略大
        XCTAssertEqual(AppTextScale.allCases.count, 5)
    }

    // 覆盖档持久化跨重启。
    func testOverridePersistsAcrossRestart() {
        TextScaleManager(store: defaults).scale = .large
        XCTAssertEqual(TextScaleManager(store: defaults).scale, .large)
    }

    // 放大沿阶梯并钳制上界（xLarge）。
    func testSteppedClampsUpper() {
        XCTAssertEqual(AppTextScale.stepped(from: .large, by: 1), .xLarge)
        XCTAssertEqual(AppTextScale.stepped(from: .xLarge, by: 1), .xLarge)
    }

    // 缩小沿阶梯并钳制下界（small）。
    func testSteppedClampsLower() {
        XCTAssertEqual(AppTextScale.stepped(from: .medium, by: -1), .small)
        XCTAssertEqual(AppTextScale.stepped(from: .small, by: -1), .small)
    }

    // reset 回跟随系统。
    func testResetReturnsToSystem() {
        let m = TextScaleManager(store: defaults)
        m.scale = .xLarge
        m.reset()
        XCTAssertEqual(m.scale, .system)
    }

    // U1：跟随系统下以有效系统档映射到最近覆盖档作基线。
    func testNearestOverrideBaseline() {
        XCTAssertEqual(AppTextScale.nearestOverride(for: .medium), .medium)
        // 比下限还小 → 钳到 .small。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .xSmall), .small)
        // 超上限 → 钳到 .xLarge。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .accessibility5), .xLarge)
        // .large 档原生即 .large：有效 .large 应映射到 .large。
        XCTAssertEqual(AppTextScale.nearestOverride(for: .large), .large)
    }

    // 根注入契约：overrideSize 为 nil 即「跟随系统」= 不注入（禁止 .dynamicTypeSize(nil)）。
    func testSystemYieldsNilOverrideForConditionalInjection() {
        let m = TextScaleManager(store: defaults)
        XCTAssertNil(m.overrideSize)          // .system → nil → modifier 走全范围（不钳制）分支
        m.scale = .xLarge
        XCTAssertEqual(m.overrideSize, .xLarge)  // 覆盖档 → 注入具体值
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
