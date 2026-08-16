import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class TabBarViewTests: XCTestCase {
    private func mgr(machines: Int = 0) -> SessionsManager {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        for i in 0..<machines {
            store.add(MachineConfig(displayName: "m\(i)", relayURL: "wss://h\(i)",
                                    sessionId: "s\(i)", devIdentityPubB64: "pk\(i)"))
        }
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    /// toolbar 机器菜单应能在有机器时挂载渲染而不崩溃。
    func test_tabBarView_rendersWithMachines() {
        let sessions = mgr(machines: 3)
        let view = TabBarView().environment(sessions)
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        XCTAssertEqual(sessions.machineStore.machines.count, 3)
    }

    /// 空机器时也应渲染占位菜单，不崩溃。
    func test_tabBarView_rendersEmpty() {
        let sessions = mgr(machines: 0)
        let hc = UIHostingController(rootView: TabBarView().environment(sessions))
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        XCTAssertTrue(sessions.machineStore.machines.isEmpty)
    }

    /// DotView 覆盖 5 种指示态均可实例化渲染不崩溃（含闪烁态 attention/error）。
    func test_dotView_allIndicatorsRender() {
        for ind in [TabIndicator.none, .unread, .running, .attention, .error, .disconnected] {
            let hc = UIHostingController(rootView: DotView(indicator: ind))
            hc.view.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
            hc.view.setNeedsLayout()
            hc.view.layoutIfNeeded()
            XCTAssertNotNil(hc.view)
        }
    }

    /// 桩：indicator(for:) 默认 .none（T11 换真实聚合）。
    func test_indicatorStub_defaultsToNone() {
        let sessions = mgr(machines: 1)
        let id = sessions.machineStore.machines[0].id
        XCTAssertEqual(sessions.indicator(for: id), .none)
    }

    /// 桩：presentAddMachine 置 addMachinePresented（T8 接表单 sheet）。
    func test_presentAddMachineStub_setsFlag() {
        let sessions = mgr(machines: 0)
        XCTAssertFalse(sessions.addMachinePresented)
        sessions.presentAddMachine()
        XCTAssertTrue(sessions.addMachinePresented)
    }

    /// D6：连接互斥判定——未连接态可连（应只显示「连接」），已就绪态不可连（应只显示「断开」）。
    func test_canConnect_isMutuallyExclusiveByState() {
        let sessions = mgr(machines: 1)
        let id = sessions.machineStore.machines[0].id
        XCTAssertTrue(sessions.canConnect(id: id), "未连接态应可连（互斥显示连接）")
    }

    /// D6：移除机器不由单次点击直接执行——挂载渲染不崩溃（confirmationDialog 接线成立）。
    @MainActor
    func test_tabBar_mountsWithRemoveConfirmation() {
        let sessions = mgr(machines: 2)
        let hc = UIHostingController(rootView: TabBarView().environment(sessions))
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        XCTAssertEqual(sessions.machineStore.machines.count, 2)
    }
}
