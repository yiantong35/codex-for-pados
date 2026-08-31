import XCTest
import UIKit
@testable import CodexRemote

/// Enter 发送（narrow-right-panel-and-enter-send）：硬件 Return 判定纯函数（UIKeyModifierFlags，
/// fallback b：UITextView pressesBegan 记录的修饰键）+ 发送单一出口 executeSendShortcut 三态直测
/// + 软键盘换行检测规格 classify（fallback b 下由 shouldChangeTextIn 等价实现，本函数保留为行为规格）。
@MainActor
final class ComposerSendInteractionTests: XCTestCase {

    // MARK: - 硬件 Return 判定（design §2a：无修饰=发送；⇧=放行换行；⌘=放行走隐形 Button 别名）

    func test_hardwareReturn_noModifiers_sends() {
        XCTAssertEqual(ComposerView.hardwareReturnAction(modifiers: []), .send)
    }

    func test_hardwareReturn_shift_passthroughForNewline() {
        XCTAssertEqual(ComposerView.hardwareReturnAction(modifiers: .shift), .passthrough)
    }

    func test_hardwareReturn_command_passthroughForAlias() {
        XCTAssertEqual(ComposerView.hardwareReturnAction(modifiers: .command), .passthrough)
    }

    func test_hardwareReturn_shiftCommand_passthrough() {
        XCTAssertEqual(ComposerView.hardwareReturnAction(modifiers: [.shift, .command]), .passthrough)
    }

    func test_hardwareReturn_capsLockAlone_stillSends() {
        // 锁定键（大写锁定）不是组合修饰意图,不得挡发送。
        XCTAssertEqual(ComposerView.hardwareReturnAction(modifiers: .alphaShift), .send)
    }

    // MARK: - executeSendShortcut 三态（空闲 send / turn 中 enqueue / 空输入 no-op）

    func test_executeSendShortcut_idle_sends() async {
        var sent = false, queued = false
        await ComposerView.executeSendShortcut(
            isEnabled: true, canSend: true, isTurnRunning: false,
            send: { sent = true }, enqueue: { queued = true })
        XCTAssertTrue(sent); XCTAssertFalse(queued)
    }

    func test_executeSendShortcut_turnRunning_enqueues() async {
        var sent = false, queued = false
        await ComposerView.executeSendShortcut(
            isEnabled: true, canSend: true, isTurnRunning: true,
            send: { sent = true }, enqueue: { queued = true })
        XCTAssertFalse(sent); XCTAssertTrue(queued)
    }

    func test_executeSendShortcut_emptyInput_noOp() async {
        // 空输入（仅空白）→ canSend=false（ComposerView.canSend 统一 guard）→ 两路皆 no-op。
        var sent = false, queued = false
        await ComposerView.executeSendShortcut(
            isEnabled: true, canSend: false, isTurnRunning: false,
            send: { sent = true }, enqueue: { queued = true })
        XCTAssertFalse(sent); XCTAssertFalse(queued)
        XCTAssertFalse(ComposerView.canSend(text: "   \n ", imageDataURL: nil, isImageLoading: false))
    }

    // MARK: - 软键盘换行检测规格 classify(old:new:)（design §2b；fallback b 下 shouldChangeTextIn 等价实现）

    func test_classify_returnAppended_triggersSendWithStrippedText() {
        XCTAssertEqual(ComposerView.classify(old: "abc", new: "abc\n"),
                       .sendTriggered(strippedText: "abc"))
    }

    func test_classify_multilinePaste_isNormal() {
        XCTAssertEqual(ComposerView.classify(old: "", new: "line1\nline2"), .normal)
    }

    func test_classify_midEditNewline_isNormal() {
        // 中间插入 \n：长度也 +1，但 new != old + "\n"，不得误发。
        XCTAssertEqual(ComposerView.classify(old: "ab\ncd", new: "ab\n\ncd"), .normal)
    }

    func test_classify_emptyStringBoundary() {
        // 空串按 Return：sendTriggered("")，汇入点 canSend guard 兜底 no-op（发送语义不在 classify）。
        XCTAssertEqual(ComposerView.classify(old: "", new: "\n"),
                       .sendTriggered(strippedText: ""))
    }

    func test_classify_strippedWritebackAndDeletion_isNormal() {
        // 消费后回填剥后文本（new 比 old 短）不得再触发（防回环）；普通删除同理。
        XCTAssertEqual(ComposerView.classify(old: "abc\n", new: "abc"), .normal)
        XCTAssertEqual(ComposerView.classify(old: "abc", new: "ab"), .normal)
    }

    // MARK: - fallback b 拦截决策纯函数（shouldChangeTextIn 的可测内核）

    func test_interceptDecision_plainReturn_noMarkedText_sends() {
        XCTAssertEqual(ComposerTextEditor.returnInterceptDecision(
            replacement: "\n", hasMarkedText: false, returnKeyModifiers: []), .consumeAndSend)
    }

    func test_interceptDecision_markedText_passesThroughForIME() {
        // 组合态（拼音候选）：绝不拦截，交系统确认候选（spec「中文输入法组合态保护」）。
        XCTAssertEqual(ComposerTextEditor.returnInterceptDecision(
            replacement: "\n", hasMarkedText: true, returnKeyModifiers: []), .passthrough)
    }

    func test_interceptDecision_shiftReturn_passesThroughForNewline() {
        XCTAssertEqual(ComposerTextEditor.returnInterceptDecision(
            replacement: "\n", hasMarkedText: false, returnKeyModifiers: .shift), .passthrough)
    }

    func test_interceptDecision_nonReturnReplacement_passesThrough() {
        // 普通打字/多行粘贴（t ≠ "\n"）：不拦截。
        XCTAssertEqual(ComposerTextEditor.returnInterceptDecision(
            replacement: "a", hasMarkedText: false, returnKeyModifiers: []), .passthrough)
        XCTAssertEqual(ComposerTextEditor.returnInterceptDecision(
            replacement: "line1\nline2", hasMarkedText: false, returnKeyModifiers: []), .passthrough)
    }
}
