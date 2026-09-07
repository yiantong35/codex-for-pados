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
        // 图标尺寸仍用 @ScaledMetric 驱动的 toolbarIconSize（动态类型下图标随档放大，仍落在 44pt 内）。
        XCTAssertTrue(src.contains("@ScaledMetric(relativeTo: .body) private var toolbarIconSize"),
                      "toolbar 图标尺寸须以 @ScaledMetric 随 Dynamic Type 缩放")
        XCTAssertTrue(src.contains(".frame(width: 44, height: 44)"),
                      "toolbar 按钮须恒定 44×44 固定尺寸，杜绝图标固有宽/字重/缩放导致的时大时小")
        XCTAssertNil(src.range(of: "minWidth: 44, minHeight: 44"),
                     "禁止旧 .frame(minWidth:minHeight:)（按内容撑开→按钮时大时小）")
        XCTAssertTrue(src.contains("contentShape(Rectangle())"),
                      "toolbar 按钮须保留 contentShape(Rectangle()) 保证命中区")
    }
}
