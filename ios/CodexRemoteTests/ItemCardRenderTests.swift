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

    func testImageAndPlanCardsBodyDoNotCrash() {
        _ = ItemCard(item: .imageGeneration(id: "1", status: "completed",
                                            revisedPrompt: "a cat", savedPath: "/tmp/c.png")).body
        _ = ItemCard(item: .imageView(id: "2", path: "/tmp/x.png")).body
        _ = ItemCard(item: .plan(id: "3", text: "读\n写")).body
        _ = ItemCard(item: .collabAgentToolCall(id: "4")).body
        _ = ItemCard(item: .subAgentActivity(id: "5")).body
    }

    // MARK: - F5（P1）会话前缀放行仅源自服务端 amendment

    private func cmdCard(title: String, prefix: [String]?, isFile: Bool = false) -> ApprovalCard {
        ApprovalCard(id: .string("c"), method: isFile ? ServerRequestMethod.fileApprovalV2 : ServerRequestMethod.cmdApprovalV2,
                     threadId: "t", title: title, detail: "/w",
                     proposedPrefix: prefix, isFileChange: isFile, isPermissions: false,
                     reason: nil, requestedNetworkEnabled: nil, requestedFileSystem: nil)
    }

    /// 无服务端 amendment：不提供前缀放行、绝不从 command[0] 本地推导。
    func test_prefix_allow_absent_without_amendment() {
        let card = cmdCard(title: "/bin/sh -c 'rm x'", prefix: nil)
        XCTAssertNil(ApprovalCardView.prefixButtonState(card: card))
    }

    /// 有服务端 amendment：展示实际前缀（原样返回，不做本地覆写）。
    func test_prefix_allow_shows_actual_amendment() {
        let card = cmdCard(title: "git status", prefix: ["git", "status"])
        XCTAssertEqual(ApprovalCardView.prefixButtonState(card: card), ["git", "status"])
    }

    /// 文件改动无前缀放行语义：即便误带 prefix 也不提供。
    func test_prefix_allow_absent_for_file_change() {
        let card = cmdCard(title: "main.swift", prefix: ["should", "ignore"], isFile: true)
        XCTAssertNil(ApprovalCardView.prefixButtonState(card: card))
    }
}
