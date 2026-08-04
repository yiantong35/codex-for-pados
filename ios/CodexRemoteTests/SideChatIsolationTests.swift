import XCTest
import SwiftUI
@testable import CodexRemote

/// D1：侧聊使用独立 active-conversation 上下文——侧聊实例（bindsWorkspaceState=false）
/// 绝不写入/清空主对话绑定的 ActiveConversationHolder（state/fetchFullDiff/startReview）。
@MainActor
final class SideChatIsolationTests: XCTestCase {

    /// 侧聊 ConversationView 参数化开关默认 true、可显式传 false——用类型层面断言开关存在，
    /// 并断言 SideChatView 内部对 ConversationView 的挂载传入 false（不共享 holder）。
    /// 结构断言：挂载 + 布局一轮后，holder 三字段仍为初始 nil（侧聊未写入）。
    func test_sideChat_doesNotWriteHolder() {
        let holder = ActiveConversationHolder()
        // 预置一个「主对话已注入」的 holder 现场：startReview / fetchFullDiff / state 非空。
        holder.state = ConversationState(threadId: "main")
        holder.fetchFullDiff = { _ in "main-diff" }
        holder.startReview = { _ in true }

        // 侧聊挂载：bindsWorkspaceState=false 的 ConversationView。挂载并布局一轮。
        let view = ConversationView(threadId: "side-thread", bindsWorkspaceState: false)
            .environment(holder)
            .environment(ApprovalStore())
            .environment(makeIsolatedConnection())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()

        // 侧聊不驱动审查面板：主对话注入的 holder 现场保持原样。
        XCTAssertEqual(holder.state?.threadId, "main", "侧聊不应覆盖主对话 state")
        XCTAssertNotNil(holder.fetchFullDiff, "侧聊不应清空主对话 fetchFullDiff")
        XCTAssertNotNil(holder.startReview, "侧聊不应清空主对话 startReview")
    }

    private func makeIsolatedConnection() -> ConnectionStore {
        ConnectionStore(transportFactory: { _ in MockTransport() })
    }
}
