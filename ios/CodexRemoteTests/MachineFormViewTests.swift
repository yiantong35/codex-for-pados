import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class MachineFormViewTests: XCTestCase {
    private func mgr(machines: Int = 0) -> SessionsManager {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        for i in 0..<machines {
            store.add(MachineConfig(displayName: "m\(i)", relayURL: "wss://r\(i)",
                                    sessionId: "s\(i)", devIdentityPubB64: "pk\(i)"))
        }
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    // MARK: - 视图渲染

    /// MachineFormView（relay 配对导入入口）可挂载渲染不崩溃。
    func test_machineFormView_rendersWithoutCrash() {
        let sessions = mgr(machines: 0)
        let hc = UIHostingController(rootView: MachineFormView().environment(sessions)
            .environment(TextScaleManager()))
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

    func test_prePairingSettings_rendersWithoutConnectionStores() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let view = PrePairingSettingsView(systemColorScheme: .light)
            .environment(ThemeManager(store: defaults))
            .environment(ClipboardPolicyStore(store: defaults))
            .environment(LocaleManager(store: defaults))
            .environment(ShortcutStore(defaults: defaults))
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
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
