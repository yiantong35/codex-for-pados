import SwiftUI
import UIKit

// Enter 发送（narrow-right-panel-and-enter-send，fallback b——spike 实证 SwiftUI onKeyPress 在
// IME 组合态仍拦 Return 会破坏候选上屏，故弃用 onKeyPress，改 UITextView 桥接精确控制）：
//  - 硬件裸 Return（无修饰、非组合态）→ 发送（consume，不插换行，焦点保持）；
//  - ⇧Return（pressesBegan 的 UIKey.modifierFlags 记录）→ 放行系统插换行；
//  - ⌘Return → 放行（隐形 Button keyboardShortcut 别名先吞，防御性不拦）；
//  - IME 组合态（markedTextRange 非空）→ 一律放行，候选确认交系统（组合态不误发）；
//  - 软键盘 Return（无硬件按键 → 修饰键记录为空）→ 同裸 Return 发送；returnKeyType=.send 改键面语义；
//  - 多行粘贴（replacement ≠ "\n"）→ 放行不发送。
// 能耗：全事件驱动零轮询；安全：纯 UI 输入面。

/// growable 1–5 行的 UITextView 子类：记录 Return 按键修饰键（shouldChangeTextIn 无修饰键信息，
/// 由 pressesBegan/Ended 维护）+ 按内容自适应高度（超 5 行转为内部滚动）。
final class ReturnInterceptingTextView: UITextView {
    /// 当前在押 Return 硬件按键的修饰键；软键盘 Return 无硬件按键 → 保持 []。
    private(set) var currentReturnKeyModifiers: UIKeyModifierFlags = []

    /// 高度上限行数（对齐旧 TextField lineLimit(1...5)）。
    private let maxLines: CGFloat = 5

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, Self.isReturnKey(key.keyCode) {
                currentReturnKeyModifiers = key.modifierFlags
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        clearReturnModifiers(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        clearReturnModifiers(presses)
        super.pressesCancelled(presses, with: event)
    }

    private func clearReturnModifiers(_ presses: Set<UIPress>) {
        for press in presses where press.key.map({ Self.isReturnKey($0.keyCode) }) == true {
            currentReturnKeyModifiers = []
        }
    }

    private static func isReturnKey(_ code: UIKeyboardHIDUsage) -> Bool {
        code == .keyboardReturnOrEnter || code == .keypadEnter
    }

    // MARK: 自适应高度（1–5 行；超出转内部滚动）

    private var lastMeasuredWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIView.noIntrinsicMetric
        guard width != UIView.noIntrinsicMetric else { return super.intrinsicContentSize }
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = (font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let maxHeight = lineHeight * maxLines + textContainerInset.top + textContainerInset.bottom
        let clamped = min(fitting.height, maxHeight)
        isScrollEnabled = fitting.height > maxHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(clamped))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 仅宽度变化时失效重算（review M1：避免每轮布局空转 invalidate,能耗原则）；
        // 文本变化路径由 textViewDidChange 显式 invalidate。
        if bounds.width != lastMeasuredWidth {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// composer 输入框的 UIKit 桥接（取代 TextField(axis:.vertical)，视觉近似 roundedBorder 由外层修饰）。
struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// 裸 Return / 软键盘 Return 触发（发送语义由调用方 executeSendShortcut 统一 guard）。
    var onSubmitSend: () -> Void

    /// Return 拦截决策（shouldChangeTextIn 的可测内核，纯函数）。
    enum InterceptDecision: Equatable { case consumeAndSend, passthrough }

    static func returnInterceptDecision(replacement: String,
                                        hasMarkedText: Bool,
                                        returnKeyModifiers: UIKeyModifierFlags) -> InterceptDecision {
        guard replacement == "\n" else { return .passthrough }            // 普通打字/多行粘贴
        guard !hasMarkedText else { return .passthrough }                 // IME 组合态：候选确认交系统
        guard ComposerView.hardwareReturnAction(modifiers: returnKeyModifiers) == .send else {
            return .passthrough                                           // ⇧/⌘/⌃/⌥：换行或别名路径
        }
        return .consumeAndSend
    }

    func makeUIView(context: Context) -> ReturnInterceptingTextView {
        let tv = ReturnInterceptingTextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.returnKeyType = .send            // 软键盘键面=发送（spec「软键盘 Return 发送」）
        tv.isScrollEnabled = false          // 1–5 行内随内容长高；超出由子类转内部滚动
        tv.textContainerInset = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: ReturnInterceptingTextView, context: Context) {
        // 陈旧捕获修复（review C2）：Coordinator 只在首挂载构造,必须每轮刷新 parent,
        // 否则 onSubmitSend 闭包永远持首次 body 求值的 ComposerView 拷贝（isEnabled 翻转失效,
        // 真实挂载路径 loading→loaded 下 Enter 被吞死）。UIViewRepresentable 标准范式。
        context.coordinator.parent = self
        // .disabled 传播（review I2）：SwiftUI .disabled 不自动作用于桥接的 UIKit 视图。
        tv.isEditable = context.environment.isEnabled
        // VoiceOver 语义（review I1）：placeholder overlay 已 accessibilityHidden,
        // 文本框本体补用途标签（跟随运行时 locale）。
        tv.accessibilityLabel = L10n.string("composer.placeholder", locale: context.environment.locale)
        if tv.text != text { tv.text = text; tv.invalidateIntrinsicContentSize() }
        // 焦点桥接：focusComposer 快捷键置 isFocused=true → becomeFirstResponder；反向经 delegate 回写。
        if isFocused, !tv.isFirstResponder, tv.window != nil {
            tv.becomeFirstResponder()
        } else if !isFocused, tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 权威尺寸（composer-height-regression hotfix）：UITextView 垂直 hugging 默认 250,
    /// SwiftUI 在 VStack 有富余空间时会把 representable 拉伸吃满（真机对话页 468pt 实证;
    /// 旧 TextField hugging 高无此问题）。实现 sizeThatFits 返回精确 clamp 高度,
    /// 结构性关闭拉伸路径;intrinsicContentSize 保留为无 proposal 场景兜底。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: ReturnInterceptingTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width ?? (uiView.bounds.width > 0 ? uiView.bounds.width : nil),
              width > 0, width.isFinite else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maxHeight = font.lineHeight * 5 + insets
        let minHeight = font.lineHeight + insets
        uiView.isScrollEnabled = fitting.height > maxHeight
        let clamped = min(max(fitting.height, minHeight), maxHeight)
        return CGSize(width: width, height: ceil(clamped))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor
        init(_ parent: ComposerTextEditor) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            tv.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText t: String) -> Bool {
            let modifiers = (tv as? ReturnInterceptingTextView)?.currentReturnKeyModifiers ?? []
            switch ComposerTextEditor.returnInterceptDecision(
                replacement: t, hasMarkedText: tv.markedTextRange != nil, returnKeyModifiers: modifiers) {
            case .consumeAndSend:
                parent.onSubmitSend()   // 空输入由 executeSendShortcut 的 canSend guard 统一 no-op
                return false            // 消费：不插换行、焦点保持（spike 附加发现①的修复）
            case .passthrough:
                return true
            }
        }
    }
}
