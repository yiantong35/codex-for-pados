import XCTest
import SwiftUI
@testable import CodexRemote

/// 右栏 intent 送达（narrow-right-panel-and-enter-send 2.1，design §2A/§4.2）：
/// 消费从 onChange+onAppear 双挂改为单一 onChange(initial:true) 后，
/// 挂载即消费（窄档 overlay 新挂载场景）/ 值变化消费 / 重挂不丢——可观测结果 =
/// `pendingRightPanelIntent` 消费即复位（nil）。环境注入范式对齐 RightPanelTabsLayoutTests。
@MainActor
final class RightPanelIntentDeliveryTests: XCTestCase {

    private func makeView(layout: WorkspaceLayoutStore) -> some View {
        RightPanelContainerView()
            .environment(ActiveConversationHolder())
            .environment(ApprovalStore())
            .environment(UserInputStore())
            .environment(McpElicitationStore())
            .environment(EnvironmentStore())
            .environment(SideChatStore())
            .environment(ConnectionStore(transportFactory: { _ in MockTransport() }))
            .environment(FileBrowserStore())
            .environment(layout)
            .environment(ShortcutStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
    }

    private func mount(_ view: some View) -> (UIHostingController<AnyView>, UIWindow) {
        let hc = UIHostingController(rootView: AnyView(view))
        hc.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        drain(hc)
        return (hc, window)
    }

    private func drain(_ hc: UIHostingController<AnyView>) {
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hc.view.layoutIfNeeded()
        }
    }

    /// ① 挂载前已有 pending intent（窄档 overlay 首次挂载）：挂载即消费（initial:true）。
    func test_pendingIntentBeforeMount_consumedOnMount() {
        let layout = WorkspaceLayoutStore()
        layout.requestRightPanel(.review)
        XCTAssertNotNil(layout.pendingRightPanelIntent)
        let (_, window) = mount(makeView(layout: layout))
        defer { window.isHidden = true }
        XCTAssertNil(layout.pendingRightPanelIntent, "挂载即消费（intent 复位）")
    }

    /// ② 挂载后值变化：onChange 消费。
    func test_intentAfterMount_consumedOnChange() {
        let layout = WorkspaceLayoutStore()
        let (hc, window) = mount(makeView(layout: layout))
        defer { window.isHidden = true }
        XCTAssertNil(layout.pendingRightPanelIntent)
        layout.requestRightPanel(.sideChat)
        drain(hc)
        XCTAssertNil(layout.pendingRightPanelIntent, "挂载后新 intent 应被 onChange 消费")
    }

    /// ③ 重挂（形态切换 identity 重建的可模拟面）：卸载期间发 intent → 重挂不丢。
    func test_remountDeliversPendingIntent() {
        let layout = WorkspaceLayoutStore()
        let (_, w1) = mount(makeView(layout: layout))
        w1.rootViewController = nil              // 真卸载 SwiftUI 子树（review M4：isHidden 不卸载,旧树仍可能消费）
        w1.isHidden = true
        layout.requestRightPanel(.files)         // 卸载期间入口/快捷键发 intent
        XCTAssertNotNil(layout.pendingRightPanelIntent)
        let (_, w2) = mount(makeView(layout: layout))
        defer { w2.isHidden = true }
        XCTAssertNil(layout.pendingRightPanelIntent, "重挂后 pending intent 不丢（时序缝回归锁）")
    }
}
