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
}
