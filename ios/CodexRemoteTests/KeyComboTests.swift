import XCTest
import SwiftUI
@testable import CodexRemote

final class KeyComboTests: XCTestCase {
    func test_codableRoundTrip() throws {
        let combo = KeyCombo(key: "d", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
    }

    func test_equality_sameKeySameModifiers() {
        XCTAssertEqual(KeyCombo(key: "b", modifiers: .command),
                       KeyCombo(key: "b", modifiers: .command))
        XCTAssertNotEqual(KeyCombo(key: "b", modifiers: .command),
                          KeyCombo(key: "b", modifiers: [.command, .shift]))
    }

    func test_equality_isCaseInsensitiveOnKey() {
        // 捕获的 shifted 字母到达时为大写（⌘⇧D → key "D"），默认用小写 "d"。
        // 两者必须相等且 hash 一致，否则占用检测/系统保留匹配/运行时派发全部失效。
        XCTAssertEqual(KeyCombo(key: "D", modifiers: [.command, .shift]),
                       KeyCombo(key: "d", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyCombo(key: "D", modifiers: [.command, .shift]).hashValue,
                       KeyCombo(key: "d", modifiers: [.command, .shift]).hashValue)
    }

    func test_modifiersRoundTripThroughRawValue() {
        let combo = KeyCombo(key: "f", modifiers: [.command, .control])
        XCTAssertTrue(combo.modifiers.contains(.command))
        XCTAssertTrue(combo.modifiers.contains(.control))
        XCTAssertFalse(combo.modifiers.contains(.shift))
    }

    func test_displayString_orderIsControlOptionShiftCommand() {
        XCTAssertEqual(KeyCombo(key: "d", modifiers: [.command, .shift]).displayString, "⇧⌘D")
        XCTAssertEqual(KeyCombo(key: "f", modifiers: [.command, .control]).displayString, "⌃⌘F")
        XCTAssertEqual(KeyCombo(key: ",", modifiers: .command).displayString, "⌘,")
    }

    func test_escapeSentinelDisplaysAsEsc() {
        XCTAssertEqual(KeyCombo(key: KeyCombo.escapeKey, modifiers: []).displayString, "esc")
    }

    /// 特性锁：Esc 归约出的键位（escapeKey + 空修饰）等于 cancelForm 的默认键位。
    /// 这正是录入态必须在构造/校验前拦截 Esc 的原因——否则一次 Esc 会被 init(keyPress:)
    /// 归约成 cancelForm 的组合键、被占用检测判 .occupied，用户无法退出录入态（死胡同）。
    func test_escapeKeyPressWouldCollideWithCancelForm() {
        XCTAssertEqual(KeyCombo(key: KeyCombo.escapeKey, modifiers: []),
                       ShortcutAction.cancelForm.defaultCombo)
    }

    // MARK: - 转 KeyEquivalent / KeyboardShortcut（Design 测试策略：转 KeyboardShortcut 覆盖）

    func test_keyEquivalent_normalKeyUsesCharacter() {
        let combo = KeyCombo(key: "d", modifiers: [.command, .shift])
        XCTAssertEqual(combo.keyEquivalent.character, "d")
    }

    func test_keyEquivalent_escapeSentinelMapsToEscape() {
        let combo = KeyCombo(key: KeyCombo.escapeKey, modifiers: [])
        XCTAssertEqual(combo.keyEquivalent, .escape)
    }

    func test_returnSentinelMapsAndDisplaysAsReturn() {
        let combo = KeyCombo(key: KeyCombo.returnKey, modifiers: .command)
        XCTAssertEqual(combo.keyEquivalent, .return)
        XCTAssertEqual(combo.displayString, "⌘return")
    }

    func test_keyboardShortcut_carriesKeyAndModifiers() {
        let shortcut = KeyCombo(key: "b", modifiers: .command).keyboardShortcut
        XCTAssertEqual(shortcut.key.character, "b")
        XCTAssertTrue(shortcut.modifiers.contains(.command))
    }

    // MARK: - init(keyPress:) 过滤语义
    //
    // KeyCombo.init(keyPress:) 依赖 SwiftUI 运行时经 onKeyPress 回调生成的 KeyPress。
    // 经查 iOS 26.5 SDK，SwiftUI.KeyPress 仅有 `public let phase/key/characters/modifiers`
    // 四个存储属性、且无任何公开初始化器，无法在单元测试中可靠构造，故不硬造 KeyPress。
    // 改为直接断言该 init 所依赖的 EventModifiers.intersection 过滤语义——即
    // “只保留 ⌘⇧⌃⌥、滤掉 capsLock/numericPad 等噪声”这一等价行为
    // （对应 KeyCombo.swift init(keyPress:) 中 keyPress.modifiers.intersection([.command,.shift,.control,.option])）。
    func test_keyPressInit_intersectionKeepsOnlyRelevantModifiers() {
        let relevant: EventModifiers = [.command, .shift, .control, .option]
        // 噪声（capsLock）+ 相关修饰（command）→ 只留 command
        XCTAssertEqual(([.command, .capsLock] as EventModifiers).intersection(relevant), .command)
        // 多个相关修饰 + 噪声（numericPad）→ 相关的全部保留、噪声被滤掉
        XCTAssertEqual(([.command, .shift, .capsLock, .numericPad] as EventModifiers).intersection(relevant),
                       [.command, .shift])
        // 纯噪声 → 空集
        XCTAssertEqual(([.capsLock, .numericPad] as EventModifiers).intersection(relevant), [])
    }
}
