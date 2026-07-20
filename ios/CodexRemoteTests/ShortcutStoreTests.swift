import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class ShortcutStoreTests: XCTestCase {
    private func store() -> (ShortcutStore, UserDefaults, String) {
        let suite = "test.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (ShortcutStore(defaults: d), d, suite)
    }

    func test_defaultQuery_returnsDefaultWhenNoOverride() {
        let (s, _, suite) = store()
        XCTAssertEqual(s.combo(for: .toggleLeftPanel), ShortcutAction.toggleLeftPanel.defaultCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_overridePrecedence() {
        let (s, _, suite) = store()
        let newCombo = KeyCombo(key: "l", modifiers: [.command, .control])
        _ = s.rebind(.toggleLeftPanel, to: newCombo)
        XCTAssertEqual(s.combo(for: .toggleLeftPanel), newCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_overridePersistsAcrossRestart() {
        let (s, d, suite) = store()
        let newCombo = KeyCombo(key: "l", modifiers: [.command, .control])
        _ = s.rebind(.toggleLeftPanel, to: newCombo)
        let reloaded = ShortcutStore(defaults: d)
        XCTAssertEqual(reloaded.combo(for: .toggleLeftPanel), newCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
