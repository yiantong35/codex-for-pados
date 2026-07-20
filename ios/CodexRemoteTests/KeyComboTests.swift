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
}
