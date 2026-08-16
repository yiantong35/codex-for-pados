import SwiftUI

/// 键位值类型（设计 D2）：单字符键 + 修饰位集。可 Codable（UserDefaults 持久化）、
/// 可 Equatable/Hashable（冲突检测比较、装入 Set）、可转 SwiftUI KeyboardShortcut。
/// `key` 存单字符；Esc 用 `escapeKey` 哨兵（`\u{1B}`）。修饰符只存 rawValue（EventModifiers 非 Codable）。
struct KeyCombo: Codable, Equatable, Hashable {
    /// 单字符键；Esc 例外，用 `KeyCombo.escapeKey` 哨兵。
    var key: String
    /// EventModifiers.rawValue（只持久化四个相关修饰：⌘⇧⌃⌥）。
    var rawModifiers: Int

    /// Esc 哨兵（KeyEquivalent.escape 的字符即 U+001B）。
    static let escapeKey = "\u{1B}"
    static let returnKey = "\r"

    init(key: String, modifiers: EventModifiers) {
        self.key = key.lowercased()
        self.rawModifiers = modifiers.rawValue
    }

    /// 从 onKeyPress 捕获构造（设计 D7）：只保留 ⌘⇧⌃⌥，滤掉 capsLock/numericPad 等噪声。
    init(keyPress: KeyPress) {
        let relevant: EventModifiers = [.command, .shift, .control, .option]
        self.key = String(keyPress.key.character).lowercased()
        self.rawModifiers = keyPress.modifiers.intersection(relevant).rawValue
    }

    var modifiers: EventModifiers { EventModifiers(rawValue: rawModifiers) }

    var keyEquivalent: KeyEquivalent {
        if key == Self.escapeKey { return .escape }
        if key == Self.returnKey { return .return }
        return KeyEquivalent(Character(key))
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    /// 展示串（Apple 顺序 ⌃⌥⇧⌘ + 键），如「⇧⌘D」「⌘,」「esc」。
    var displayString: String {
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        if key == Self.escapeKey { s += "esc" }
        else if key == Self.returnKey { s += "return" }
        else { s += key.uppercased() }
        return s
    }
}
