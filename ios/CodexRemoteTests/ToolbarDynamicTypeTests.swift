import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class ToolbarDynamicTypeTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                 // CodexRemoteTests/
        .deletingLastPathComponent()                 // ios/
        .appendingPathComponent("CodexRemote/Views/RootSplitView.swift")

    func test_toolbarLabel_usesScaledDynamicTypeFont() throws {
        let src = try String(contentsOf: sourceURL, encoding: .utf8)
        // 必须用 @ScaledMetric 驱动的图标尺寸，禁止固定 size(21) 手写。
        XCTAssertTrue(src.contains("@ScaledMetric(relativeTo: .body) private var toolbarIconSize"),
                      "toolbar 图标尺寸须以 @ScaledMetric 随 Dynamic Type 缩放，仍出现固定字号")
        XCTAssertTrue(src.contains("minWidth: 44, minHeight: 44"),
                      "toolbar 按钮须保留 ≥44pt 最小点击区")
        XCTAssertNil(src.range(of: ".font(.system(size: 21"),
                     "出现固定 .system(size:21) 不动点，应删除或改为 toolbarIconSize")
    }
}
