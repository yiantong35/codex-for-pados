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
        // #5：用随外观缩放但恒定的 frame 兜底 ≥44pt，禁止旧的 minWidth:minHeight（按内容撑开→按钮时大时小）。
        XCTAssertTrue(src.contains("max(toolbarIconSize * 2, 44)"),
                      "toolbar 按钮须以 max(toolbarIconSize * 2, 44) 保底 ≥44pt 点击区且随 Dynamic Type 缩放")
        XCTAssertNil(src.range(of: ".system(size: 21"),   // 兼容 .font(.system(size: toolbarIconSize...)) 写法
                     "出现固定 .system(size:21) 不动点，应删除或改为 toolbarIconSize")
        XCTAssertTrue(src.contains("contentShape(Rectangle())"),
                      "toolbar 按钮须保留 contentShape(Rectangle()) 保证命中区")
    }
}
