import XCTest
import SwiftUI
@testable import CodexRemote

final class ShortcutActionTests: XCTestCase {
    func test_exactly22Actions() {
        XCTAssertEqual(ShortcutAction.allCases.count, 22)
    }

    func test_rawValuesUnique() {
        let raws = ShortcutAction.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    func test_onlyCancelFormIsFixed() {
        for a in ShortcutAction.allCases {
            XCTAssertEqual(a.isCustomizable, a != .cancelForm, "\(a) 可改性错误")
        }
    }

    func test_defaultBindings_sample() {
        XCTAssertEqual(ShortcutAction.tab1.defaultCombo, KeyCombo(key: "1", modifiers: .command))
        XCTAssertEqual(ShortcutAction.nextTab.defaultCombo, KeyCombo(key: "]", modifiers: .command))
        XCTAssertEqual(ShortcutAction.prevTab.defaultCombo, KeyCombo(key: "[", modifiers: .command))
        XCTAssertEqual(ShortcutAction.addMachine.defaultCombo, KeyCombo(key: "t", modifiers: .command))
        XCTAssertEqual(ShortcutAction.toggleLeftPanel.defaultCombo, KeyCombo(key: "b", modifiers: .command))
        XCTAssertEqual(ShortcutAction.toggleRightPanel.defaultCombo, KeyCombo(key: "b", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutAction.toggleBottomPanel.defaultCombo, KeyCombo(key: "j", modifiers: .command))
        XCTAssertEqual(ShortcutAction.toggleSummary.defaultCombo, KeyCombo(key: "i", modifiers: .command))
        XCTAssertEqual(ShortcutAction.openSettings.defaultCombo, KeyCombo(key: ",", modifiers: .command))
        XCTAssertEqual(ShortcutAction.rightPanelReview.defaultCombo, KeyCombo(key: "d", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutAction.rightPanelFiles.defaultCombo, KeyCombo(key: "f", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutAction.rightPanelSideChat.defaultCombo, KeyCombo(key: "c", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutAction.rightPanelFullscreen.defaultCombo, KeyCombo(key: "f", modifiers: [.command, .control]))
        XCTAssertEqual(ShortcutAction.cancelForm.defaultCombo, KeyCombo(key: KeyCombo.escapeKey, modifiers: []))
    }

    /// 回归锁：任意两个内置动作不得共用同一默认组合键，防未来新增内置键位撞车。
    func test_defaultCombos_pairwiseUnique() {
        let combos = ShortcutAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count, "存在默认组合键冲突：两个动作共用同一 KeyCombo")
    }

    func test_scopes() {
        XCTAssertEqual(ShortcutAction.tab1.scope, .global)
        XCTAssertEqual(ShortcutAction.toggleLeftPanel.scope, .workspace)
        XCTAssertEqual(ShortcutAction.rightPanelFiles.scope, .workspace)
        XCTAssertEqual(ShortcutAction.cancelForm.scope, .form)
    }
}
