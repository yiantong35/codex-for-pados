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

    func test_rebind_rejectsSystemReserved_keepsOriginal() {
        let (s, _, suite) = store()
        let original = s.combo(for: .toggleLeftPanel)
        let result = s.rebind(.toggleLeftPanel, to: KeyCombo(key: " ", modifiers: .command)) // ⌘Space
        XCTAssertEqual(result, .rejected(.systemReserved))
        XCTAssertEqual(s.combo(for: .toggleLeftPanel), original, "拒绝时原绑定必须保持")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_rejectsInternalConflict_withOccupantName() {
        let (s, _, suite) = store()
        // ⌘J 默认属 toggleBottomPanel；把 toggleSummary 绑到 ⌘J 应被判占用。
        let result = s.rebind(.toggleSummary, to: KeyCombo(key: "j", modifiers: .command))
        XCTAssertEqual(result, .rejected(.occupied(by: .toggleBottomPanel)))
        XCTAssertEqual(s.combo(for: .toggleSummary), ShortcutAction.toggleSummary.defaultCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_acceptsFreeKey() {
        let (s, _, suite) = store()
        let free = KeyCombo(key: "k", modifiers: [.command, .shift]) // 未被任何默认占用
        XCTAssertEqual(s.rebind(.toggleSummary, to: free), .accepted)
        XCTAssertEqual(s.combo(for: .toggleSummary), free)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_toSameActionOwnKey_isAccepted() {
        let (s, _, suite) = store()
        // 绑到自己当前的键不算冲突。
        let same = s.combo(for: .toggleSummary)
        XCTAssertEqual(s.rebind(.toggleSummary, to: same), .accepted)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_resetToDefault() {
        let (s, _, suite) = store()
        _ = s.rebind(.toggleSummary, to: KeyCombo(key: "k", modifiers: [.command, .shift]))
        XCTAssertTrue(s.isOverridden(.toggleSummary))
        s.resetToDefault(.toggleSummary)
        XCTAssertFalse(s.isOverridden(.toggleSummary))
        XCTAssertEqual(s.combo(for: .toggleSummary), ShortcutAction.toggleSummary.defaultCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_resetAll() {
        let (s, _, suite) = store()
        _ = s.rebind(.toggleSummary, to: KeyCombo(key: "k", modifiers: [.command, .shift]))
        _ = s.rebind(.toggleBottomPanel, to: KeyCombo(key: "m", modifiers: [.command, .shift]))
        s.resetAll()
        XCTAssertFalse(s.isOverridden(.toggleSummary))
        XCTAssertFalse(s.isOverridden(.toggleBottomPanel))
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
