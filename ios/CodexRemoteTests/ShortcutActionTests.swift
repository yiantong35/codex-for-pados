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

    func test_scopes() {
        XCTAssertEqual(ShortcutAction.tab1.scope, .global)
        XCTAssertEqual(ShortcutAction.toggleLeftPanel.scope, .workspace)
        XCTAssertEqual(ShortcutAction.rightPanelFiles.scope, .workspace)
        XCTAssertEqual(ShortcutAction.cancelForm.scope, .form)
    }
}
