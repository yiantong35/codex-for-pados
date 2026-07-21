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

    // MARK: - M2 最小修饰键守卫（需含 ⌘ 或 ⌃；⇧/⌥ 单独不满足）

    func test_rebind_rejectsBareKey_missingRequiredModifier() {
        let (s, _, suite) = store()
        let original = s.combo(for: .toggleSummary)
        let result = s.rebind(.toggleSummary, to: KeyCombo(key: "f", modifiers: [])) // 裸键 f
        XCTAssertEqual(result, .rejected(.missingRequiredModifier))
        XCTAssertEqual(s.combo(for: .toggleSummary), original, "拒绝时原绑定必须保持")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_rejectsShiftOnly_missingRequiredModifier() {
        let (s, _, suite) = store()
        let result = s.rebind(.toggleSummary, to: KeyCombo(key: "f", modifiers: .shift)) // 仅 ⇧
        XCTAssertEqual(result, .rejected(.missingRequiredModifier))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_rejectsOptionOnly_missingRequiredModifier() {
        let (s, _, suite) = store()
        let result = s.rebind(.toggleSummary, to: KeyCombo(key: "f", modifiers: .option)) // 仅 ⌥
        XCTAssertEqual(result, .rejected(.missingRequiredModifier))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_acceptsCommandModifier_passesGuard() {
        let (s, _, suite) = store()
        let free = KeyCombo(key: "k", modifiers: [.command, .shift]) // 含 ⌘，未占用
        XCTAssertEqual(s.rebind(.toggleSummary, to: free), .accepted)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_acceptsControlModifier_passesGuard() {
        let (s, _, suite) = store()
        let free = KeyCombo(key: "k", modifiers: .control) // 仅 ⌃，未占用
        XCTAssertEqual(s.rebind(.toggleSummary, to: free), .accepted)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_toSameActionOwnKey_isAccepted() {
        let (s, _, suite) = store()
        // 绑到自己当前的键不算冲突。
        let same = s.combo(for: .toggleSummary)
        XCTAssertEqual(s.rebind(.toggleSummary, to: same), .accepted)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_rejectsCollisionWithFixedAction_cancelForm() {
        let (s, _, suite) = store()
        // cancelForm（固定）默认 Esc。把 openSettings 绑到 Esc 必须判占用（含固定动作）。
        let esc = KeyCombo(key: KeyCombo.escapeKey, modifiers: [])
        let result = s.rebind(.openSettings, to: esc)
        XCTAssertEqual(result, .rejected(.occupied(by: .cancelForm)))
        XCTAssertEqual(s.combo(for: .openSettings), ShortcutAction.openSettings.defaultCombo)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_occupancy_comparesOverrideAppliedCombos() {
        let (s, _, suite) = store()
        let cmdM = KeyCombo(key: "m", modifiers: .command) // ⌘M 未被任何默认占用
        XCTAssertEqual(s.rebind(.toggleBottomPanel, to: cmdM), .accepted)
        // ⌘M 现被 toggleBottomPanel 的覆盖占用 → toggleSummary 绑 ⌘M 应判占用。
        XCTAssertEqual(s.rebind(.toggleSummary, to: cmdM),
                       .rejected(.occupied(by: .toggleBottomPanel)))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_occupancy_freedDefaultKeyBecomesReusable() {
        let (s, _, suite) = store()
        let cmdM = KeyCombo(key: "m", modifiers: .command)
        let cmdJ = KeyCombo(key: "j", modifiers: .command) // toggleBottomPanel 默认键
        XCTAssertEqual(s.rebind(.toggleBottomPanel, to: cmdM), .accepted)
        // toggleBottomPanel 已改到 ⌘M，其默认 ⌘J 应重新可用。
        XCTAssertEqual(s.rebind(.toggleSummary, to: cmdJ), .accepted)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func test_rebind_fixedAction_rejectedAsNotCustomizable() {
        let (s, _, suite) = store()
        let free = KeyCombo(key: "y", modifiers: [.command, .shift]) // 未被占用
        let result = s.rebind(.cancelForm, to: free)
        XCTAssertEqual(result, .rejected(.notCustomizable))
        XCTAssertEqual(s.combo(for: .cancelForm), ShortcutAction.cancelForm.defaultCombo)
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

    // MARK: - 录入态决策（recordingOutcome，Task 13 状态机）
    //
    // 录入态捕获一次按键后的纯决策，独立于 View @State，故可单测。
    // View 只把结果映射为 exitRecording()/rejection 回显。

    /// Esc 必须判「取消录入」——绝不当作组合键走 rebind、原绑定保持不变。
    /// （否则 Esc 经 init(keyPress:) 归约成 cancelForm 默认键位、被占用检测判 .occupied 而死循环。）
    func test_recordingOutcome_escapeCancels_withoutMutating() {
        let (s, _, suite) = store()
        let original = s.combo(for: .openSettings)
        let outcome = s.recordingOutcome(for: .openSettings,
                                         isEscape: true,
                                         combo: KeyCombo(key: KeyCombo.escapeKey, modifiers: []))
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(s.combo(for: .openSettings), original, "取消不得改动绑定")
        XCTAssertFalse(s.isOverridden(.openSettings))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// 占用键回显：结果必须携带占用动作（FIX 1 冲突提示插值的数据来源）。
    func test_recordingOutcome_occupiedKey_carriesOccupantAction() {
        let (s, _, suite) = store()
        let outcome = s.recordingOutcome(for: .toggleSummary,
                                         isEscape: false,
                                         combo: KeyCombo(key: "j", modifiers: .command)) // ⌘J = toggleBottomPanel
        XCTAssertEqual(outcome, .rejected(.occupied(by: .toggleBottomPanel)))
        XCTAssertEqual(s.combo(for: .toggleSummary), ShortcutAction.toggleSummary.defaultCombo, "拒绝时原绑定保持")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// 自由键：接受并持久化。
    func test_recordingOutcome_freeKey_acceptsAndPersists() {
        let (s, _, suite) = store()
        let free = KeyCombo(key: "k", modifiers: [.command, .shift])
        let outcome = s.recordingOutcome(for: .toggleSummary, isEscape: false, combo: free)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(s.combo(for: .toggleSummary), free)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
