import XCTest
import SwiftUI
@testable import CodexRemote

/// 真机回归复现（2026-08-31）：对话区大容器里 composer 的 UITextView 不得吃满可用高度——
/// 空文本时应保持单行量级（≤5 行上限），多余空间归对话列表。
@MainActor
final class ComposerHeightRegressionTests: XCTestCase {

    func test_composerTextView_doesNotExpandInTallContainer() {
        let rpc = JSONRPCClient(transport: MockTransport())
        let store = ConversationStore(rpc: rpc, threadId: "height-test")
        let draft = ComposerDraft()
        // 模拟 ConversationView 拓扑:上方内容 + 底部 composer,容器高 1000
        let view = VStack(spacing: 0) {
            Color.clear
            ComposerView(store: store, draft: draft)
        }
        .environment(EnvironmentStore())
        .environment(ShortcutStore())

        let hc = UIHostingController(rootView: AnyView(view))
        hc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 1000)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hc.view.layoutIfNeeded()
        }
        defer { window.isHidden = true }

        guard let tv = Self.descendants(of: window).compactMap({ $0 as? UITextView }).first else {
            return XCTFail("Composer must render a UITextView")
        }
        let maxFiveLines = UIFont.preferredFont(forTextStyle: .body).lineHeight * 5 + 40
        XCTAssertLessThanOrEqual(tv.frame.height, maxFiveLines,
            "空文本 composer 不得吃满大容器（实测 \(tv.frame.height)pt,五行上限约 \(maxFiveLines)pt）")
    }

    private static func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }
}
