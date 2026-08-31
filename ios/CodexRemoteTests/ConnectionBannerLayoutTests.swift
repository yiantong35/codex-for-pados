import XCTest
import SwiftUI
@testable import CodexRemote

/// connection-banner-toast：横幅浮层化——布局零位移锁。
/// ① 结构性断言（仓库既有范式,对齐 toolbar 测试）：banner 挂 overlay 而非 VStack 分支。
/// ② 行为断言：胶囊浮层限宽,不再整宽占满(整宽=旧推挤布局形态的特征)。
@MainActor
final class ConnectionBannerLayoutTests: XCTestCase {

    func test_banner_mountedAsOverlay_notVStackBranch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/RootSplitView.swift"),
            encoding: .utf8)
        // banner 必须在 overlay(alignment: .top) 内挂载
        guard let overlayRange = src.range(of: ".overlay(alignment: .top) {") else {
            return XCTFail("横幅必须经 .overlay(alignment: .top) 挂载（布局零位移）")
        }
        let afterOverlay = src[overlayRange.upperBound...].prefix(400)
        XCTAssertTrue(afterOverlay.contains("ConnectionBanner("),
                      "overlay(alignment:.top) 块内应挂 ConnectionBanner")
        // VStack 内不得再有 banner 条件分支（旧形态：if let state 在 resizableColumns 之前）
        if let vstackRange = src.range(of: "VStack(spacing: 0) {"),
           let columnsRange = src.range(of: "resizableColumns") {
            let between = src[vstackRange.upperBound..<columnsRange.lowerBound]
            XCTAssertFalse(between.contains("ConnectionBanner("),
                           "VStack 内 resizableColumns 之前不得再挂横幅（会推挤布局）")
        }
    }

    func test_banner_capsuleIsWidthBounded() {
        let banner = ConnectionBanner(state: .reconnecting, onReconnect: {},
                                      onShowDetails: { _ in }, onRePair: {})
        let hc = UIHostingController(rootView: AnyView(banner))
        let fitting = hc.sizeThatFits(in: CGSize(width: 1200, height: 400))
        XCTAssertLessThanOrEqual(fitting.width, 560,
            "胶囊浮层应限宽(≤520+边距),不得整宽占满 1200pt 容器(实测 \(fitting.width)pt)")
    }
}
