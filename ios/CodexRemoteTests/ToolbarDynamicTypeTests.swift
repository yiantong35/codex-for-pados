import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class ToolbarDynamicTypeTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                 // CodexRemoteTests/
        .deletingLastPathComponent()                 // ios/
        .appendingPathComponent("CodexRemote/Views/RootSplitView.swift")

    func test_toolbarLabel_usesFixedRegularFontIndependentOfDynamicType() throws {
        let src = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(src.contains("@ScaledMetric(relativeTo: .body) private var toolbarIconSize"),
                       "toolbar 图标不得随 Dynamic Type 缩放")
        XCTAssertTrue(src.contains(".font(.system(size: 21, weight: .regular))"),
                      "toolbar 图标必须固定为 21pt regular")
        XCTAssertFalse(src.contains("weight: selected ? .semibold : .regular"),
                       "选中状态不得改变 toolbar 图标字重")
        XCTAssertTrue(src.contains(".frame(width: 44, height: 44)"),
                      "toolbar 按钮须恒定 44×44 固定尺寸，杜绝图标固有宽/字重/缩放导致的时大时小")
        XCTAssertNil(src.range(of: "minWidth: 44, minHeight: 44"),
                     "禁止旧 .frame(minWidth:minHeight:)（按内容撑开→按钮时大时小）")
        XCTAssertTrue(src.contains("contentShape(Rectangle())"),
                      "toolbar 按钮须保留 contentShape(Rectangle()) 保证命中区")
    }
}
