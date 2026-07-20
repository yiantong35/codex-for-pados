import XCTest
import SwiftUI
@testable import CodexRemote

final class SystemReservedShortcutsTests: XCTestCase {
    func test_containsKnownReservedKeys() {
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: " ", modifiers: .command)))   // ⌘Space
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: "\t", modifiers: .command)))  // ⌘Tab
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: "h", modifiers: .command)))    // ⌘H
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: "`", modifiers: .command)))    // ⌘`
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: "3", modifiers: [.command, .shift]))) // ⌘⇧3
        XCTAssertTrue(SystemReservedShortcuts.all.contains(KeyCombo(key: "4", modifiers: [.command, .shift]))) // ⌘⇧4
    }

    func test_doesNotContainAppDefaults() {
        // app 默认键不应误列入黑名单（否则默认态即冲突）。
        XCTAssertFalse(SystemReservedShortcuts.all.contains(KeyCombo(key: "b", modifiers: .command)))       // ⌘B
        XCTAssertFalse(SystemReservedShortcuts.all.contains(KeyCombo(key: "d", modifiers: [.command, .shift]))) // ⌘⇧D
    }
}
