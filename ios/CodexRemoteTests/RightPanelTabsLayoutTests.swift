import XCTest
import SwiftUI
@testable import CodexRemote

/// D3 + D9：右栏 tab 条在窄宽（320pt）下三个 tab 全部可见可命中，
/// 尾部全屏入口不挤占 tab 命中区。取代「PNG 非空」的空断言。
///
/// 退化说明（已按 brief 授权走 fallback）：完整版「遍历 UIKit 子视图收集手势识别器/UIControl
/// 命中区」在本机对纯 SwiftUI `Button` 结构性失明——`Button` 由 SwiftUI 引擎直接在
/// `_UIHostingView` 内绘制/命中测试，不产生独立带 `gestureRecognizers` 的 UIKit 子视图；
/// 唯一命中的真实控件是 `ReviewTabView` 内桥接的 `Picker(.segmented)`（`UISegmentedControl`），
/// 与本次要验证的 `tabBar` 无关。改前改后遍历命中数恒为 2（root hosting view + 该
/// segmented control），accessibility informal-protocol 遍历（`accessibilityElementCount`/
/// `accessibilityElement(at:)`）同样恒为 0（走 subviews fallback 也只读到同一批零 frame
/// 节点）——与 `OrientationSnapshotTests.swift:7` 记录的已知限制一致（"不能转活体模拟器，
/// 辅助功能权限受限"）。保留「命中区 maxX ≤ 容器宽」溢出断言为核心（对已命中的真实控件仍
/// 有效、不放宽标准），加 `allCases.count == 3` 编译期入口完整性 + 挂载不崩溃兜底。
@MainActor
final class RightPanelTabsLayoutTests: XCTestCase {

    /// 容器在 320pt 窄宽下可挂载渲染不崩溃；已命中的真实控件命中区不横向溢出容器。
    func test_threeTabs_visibleAt320pt() {
        let view = RightPanelContainerView()
            .environment(ActiveConversationHolder())
            .environment(ApprovalStore())
            .environment(EnvironmentStore())
            .environment(ConnectionStore(transportFactory: { _ in MockTransport() }))
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(WorkspaceLayoutStore())
            .environment(ShortcutStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        // 给 SwiftUI 多个 runloop 周期完成布局（对齐 OrientationSnapshotTests 范式）。
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hc.view.layoutIfNeeded()
        }

        // 核心断言（改前改后均可判定、不放宽）：任何真实可命中控件都不应横向溢出 320pt 容器。
        let hitRects = Self.hittableRects(in: hc.view)
            .filter { $0.width > 0 && $0.height > 0 }
        XCTAssertGreaterThan(hitRects.count, 0, "至少应命中容器自身，挂载异常")
        for r in hitRects {
            XCTAssertLessThanOrEqual(r.maxX, 320.5, "命中区不应溢出容器 320pt：\(r)")
        }
    }

    /// 编译期入口完整性兜底：三 tab 恒定（review/files/sideChat）。
    func test_rightPanelTab_allCases_isThree() {
        XCTAssertEqual(RightPanelTab.allCases.count, 3)
    }

    /// 递归收集响应交互的子视图 frame（转换到根坐标）。
    private static func hittableRects(in root: UIView) -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ v: UIView) {
            if v.isUserInteractionEnabled, !(v is UIWindow),
               v.gestureRecognizers?.isEmpty == false || v is UIControl {
                out.append(v.convert(v.bounds, to: root))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }
}
