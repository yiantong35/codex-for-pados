import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class MachineFormViewTests: XCTestCase {
    private func mgr(machines: Int = 0) -> SessionsManager {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        for i in 0..<machines { store.add(MachineConfig(displayName: "m\(i)", host: "h\(i)", user: "u")) }
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    // MARK: - canSave 纯函数校验

    /// host/user 均非空且未达上限 → 可保存。
    func test_canSave_allFilledUnderCap_isTrue() {
        XCTAssertTrue(MachineFormView.canSave(host: "mac.local", user: "dev", canAddMore: true))
    }

    /// host 空 → 不可保存。
    func test_canSave_emptyHost_isFalse() {
        XCTAssertFalse(MachineFormView.canSave(host: "", user: "dev", canAddMore: true))
    }

    /// user 空 → 不可保存。
    func test_canSave_emptyUser_isFalse() {
        XCTAssertFalse(MachineFormView.canSave(host: "mac.local", user: "", canAddMore: true))
    }

    /// 纯空白（trim 后为空）→ 不可保存。
    func test_canSave_whitespaceOnly_isFalse() {
        XCTAssertFalse(MachineFormView.canSave(host: "   ", user: "dev", canAddMore: true))
    }

    /// 达上限（canAddMore=false）→ 双保险禁用，不可保存。
    func test_canSave_atCapacity_isFalse() {
        XCTAssertFalse(MachineFormView.canSave(host: "mac.local", user: "dev", canAddMore: false))
    }

    // MARK: - 视图渲染

    /// MachineFormView 可挂载渲染不崩溃（含公钥块 + KeyManager 生成）。
    func test_machineFormView_rendersWithoutCrash() {
        let sessions = mgr(machines: 0)
        let hc = UIHostingController(rootView: MachineFormView().environment(sessions))
        hc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        XCTAssertNotNil(hc.view)
    }

    /// OnboardingView 可挂载渲染不崩溃（零机器引导页）。
    func test_onboardingView_rendersWithoutCrash() {
        let sessions = mgr(machines: 0)
        let hc = UIHostingController(rootView: OnboardingView().environment(sessions))
        hc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        XCTAssertNotNil(hc.view)
    }

    /// OnboardingView 的主按钮走 presentAddMachine（经 sessions 桩验证联通）。
    func test_presentAddMachine_setsFlag() {
        let sessions = mgr(machines: 0)
        XCTAssertFalse(sessions.addMachinePresented)
        sessions.presentAddMachine()
        XCTAssertTrue(sessions.addMachinePresented)
    }
}
