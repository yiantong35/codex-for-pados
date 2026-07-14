import XCTest
import SwiftUI
@testable import CodexRemote

// ItemCard 渲染存在性断言：构造每个 case 的卡片，确保 body 不崩溃。
// SwiftUI View 的 body 在单测中求值以覆盖 switch 分支。
@MainActor
final class ItemCardRenderTests: XCTestCase {
    // 各 case 的用例随 Task 逐步补齐。
    func testUnknownCardBodyDoesNotCrash() {
        _ = ItemCard(item: .unknown(id: "x", type: "futureType")).body
    }

    func testToolCardsBodyDoNotCrash() {
        _ = ItemCard(item: .mcpToolCall(id: "1", server: "fs", tool: "read",
                                        status: "completed", result: "ok", durationMs: 8)).body
        _ = ItemCard(item: .dynamicToolCall(id: "2", namespace: "shell", tool: "exec",
                                            status: "completed", success: true)).body
        _ = ItemCard(item: .webSearch(id: "3", query: "swift", action: "search")).body
    }

    func testEventCardsBodyDoNotCrash() {
        _ = ItemCard(item: .contextCompaction(id: "1")).body
        _ = ItemCard(item: .enteredReviewMode(id: "2")).body
        _ = ItemCard(item: .exitedReviewMode(id: "3")).body
        _ = ItemCard(item: .hookPrompt(id: "4", fragments: "hook body")).body
    }
}
