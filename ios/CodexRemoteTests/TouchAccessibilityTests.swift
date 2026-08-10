import XCTest
import SwiftUI
@testable import CodexRemote

/// D7（tasks 2.6/2.7）：图标按钮 44pt 命中框 + 语义标签。
///
/// 环境限制（见 `RightPanelTabsLayoutTests.swift:8-17` 记录并本会话复现）：纯 SwiftUI `Button`
/// 在离屏 XCTest 宿主里既不产生带 gestureRecognizer 的 UIKit 子视图、无障碍树也读不到——
/// 无法直接遍历 composer 五枚图标按钮的命中框。故命中框验证收敛到**生产共用修饰符**
/// `minimumHitTarget44()`（五枚按钮统一施加）在真实 SwiftUI 布局下的度量：20pt 基线图标 <44pt 宽，
/// 施加后宽高均 ≥44pt。语义标签验证走本地化键可解析（缺键回落键名本身）。
@MainActor
final class TouchAccessibilityTests: XCTestCase {

    /// SwiftUI 视图理想尺寸：挂进 keyWindow 布局若干 runloop 周期后取 `sizeThatFits`。
    private func fittingSize<V: View>(_ view: V, width: CGFloat = 600) -> CGSize {
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hc.view.layoutIfNeeded()
        }
        return hc.sizeThatFits(in: CGSize(width: width, height: 400))
    }

    /// 2.6：命中框修饰符把小图标撑到 ≥44×44pt（HIG 最小命中目标）。
    /// 基线断言（裸图标 <44pt 宽）确保修饰符确有其功、测试非空转。
    func test_minimumHitTarget44_enforces44ptOnSmallIcon() {
        // composer 主操作图标按钮字号（发送/停止/更多 = .title2）。
        let icon = Image(systemName: "arrow.up.circle.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)

        let bare = fittingSize(icon)
        XCTAssertLessThan(bare.width, 44,
            "基线前提：裸图标应 <44pt 宽，否则命中框断言无意义（实测宽 \(bare.width)）")

        let hit = fittingSize(icon.minimumHitTarget44())
        XCTAssertGreaterThanOrEqual(hit.width, 44, "命中框宽应 ≥44pt（实测 \(hit.width)）")
        XCTAssertGreaterThanOrEqual(hit.height, 44, "命中框高应 ≥44pt（实测 \(hit.height)）")
    }

    /// 2.7：composer 五枚图标按钮语义标签的本地化键须可解析（缺键回落为键名本身）。
    func test_composerAccessibilityLabelKeys_areLocalized() {
        for key in ["composer.a11y.pickImage", "composer.a11y.model",
                    "composer.a11y.stop", "composer.a11y.send", "composer.a11y.more"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少无障碍标签本地化键 \(key)")
        }
    }

    /// 2.2b：只有含 plan progress 的卡片才提供展开/收起控件。
    /// diff-only 卡片不能暴露一个点击后无动作的伪按钮。
    func test_progressCardExpandControl_requiresPlanProgress() {
        let empty = WorkspaceSummary.PlanProgress(steps: [])
        let withPlan = WorkspaceSummary.PlanProgress(steps: [
            TurnPlanStep(step: "Inspect", status: .inProgress),
        ])

        XCTAssertFalse(ProgressCardBar.showsExpandControl(for: empty))
        XCTAssertTrue(ProgressCardBar.showsExpandControl(for: withPlan))
    }

    func test_progressCardFilesControl_requiresDiffAndNavigationAction() {
        let empty = WorkspaceSummary.DiffLineCounts(added: 0, removed: 0, changedFiles: 0)
        let changed = WorkspaceSummary.DiffLineCounts(added: 2, removed: 1, changedFiles: 1)

        XCTAssertFalse(ProgressCardBar.showsFilesControl(diff: empty, hasAction: true))
        XCTAssertFalse(ProgressCardBar.showsFilesControl(diff: changed, hasAction: false))
        XCTAssertTrue(ProgressCardBar.showsFilesControl(diff: changed, hasAction: true))
    }

    func test_progressCardAccessibilityLabelKeys_areLocalized() {
        for key in ["progress.expand", "progress.collapse"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少进度卡无障碍标签本地化键 \(key)")
        }
    }

    func test_machineStatusAccessibilityKeys_areLocalized() {
        for key in ["tab.status.none", "tab.status.unread", "tab.status.running",
                    "tab.status.attention", "tab.status.error", "tab.status.disconnected"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少机器状态无障碍文案 \(key)")
        }
    }

    func test_followupAccessibilityKeys_areLocalized() {
        for key in ["rightPanel.fullscreen.enter", "rightPanel.fullscreen.exit",
                    "review.start", "relayImport.placeholder", "accessibility.selected",
                    "accessibility.notSelected", "userInput.autoResume"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少无障碍文案 \(key)")
        }
    }

    func test_protocolPresentationKeys_areLocalized() {
        for key in ["composer.effort.none", "composer.effort.minimal", "composer.effort.low",
                    "composer.effort.medium", "composer.effort.high", "composer.effort.xhigh",
                    "conv.status.running", "conv.status.completed", "conv.status.failed",
                    "conv.status.pending", "conv.status.cancelled", "conv.status.declined",
                    "conv.status.unknown", "conv.image.unavailable", "settings.skills.updateFailed"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少用户可见协议状态文案 \(key)")
        }
    }
}
