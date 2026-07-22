import XCTest
import SwiftUI
import RelayProtocol
@testable import CodexRemote

@MainActor
final class RelayPairingImportViewModelTests: XCTestCase {
    func testValidPasteParsesToMachineConfig() throws {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=9999999999"
        let cfg = try vm.makeMachineConfig(now: 1)
        if case .relay = cfg.connection {} else { XCTFail("expected .relay connection") }
    }

    func testExpiredPayloadRejected() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=1000"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 2000))
    }

    func testGarbageRejectedWithMessage() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "not a url"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 1))
    }

    // MARK: - 横竖屏适配快照（UI 基线自检，非永久回归断言）
    // 与 OrientationSnapshotTests 同法：UIHostingController 挂进 keyWindow，
    // 在 iPad 11" 竖屏/横屏尺寸渲染成 PNG 落 /tmp/relaypair/ 供目视。
    // simctl ui tap 在当前 Xcode 不可用，改用此法验证两朝向布局不崩、卡片居中不溢出。

    private let portrait = CGSize(width: 834, height: 1194)
    private let landscape = CGSize(width: 1194, height: 834)

    private func makeSessions() -> SessionsManager {
        let d = UserDefaults(suiteName: "relaypair.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    @discardableResult
    private func snapshot(_ view: some View, size: CGSize, name: String) -> UIWindow {
        let dir = "/tmp/relaypair"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.backgroundColor = .systemBackground
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            hc.view.layoutIfNeeded()
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in window.layer.render(in: ctx.cgContext) }
        if let png = image.pngData() {
            FileManager.default.createFile(atPath: "\(dir)/\(name).png", contents: png)
            XCTAssertGreaterThan(png.count, 1000, "PNG 过小疑似空白: \(name)")
        } else {
            XCTFail("PNG 编码失败: \(name)")
        }
        return window
    }

    /// relay 导入界面竖屏：粘贴框 + 提示 + 按钮居中卡片，渲染不崩、PNG 非空。
    func test_relayImport_portrait_snapshot() {
        let view = NavigationStack { RelayPairingImportView() }
            .environment(makeSessions())
        snapshot(view, size: portrait, name: "import-portrait")
    }

    /// relay 导入界面横屏。
    func test_relayImport_landscape_snapshot() {
        let view = NavigationStack { RelayPairingImportView() }
            .environment(makeSessions())
        snapshot(view, size: landscape, name: "import-landscape")
    }

    /// 加机器表单 relay 入口本地化键须可解析（解析失败回落键名本身）。
    func test_relayImport_localization_keys_present() {
        for key in ["machineForm.mode", "machineForm.mode.ssh", "machineForm.mode.relay",
                    "relayImport.title", "relayImport.hint", "relayImport.paste",
                    "relayImport.import", "relayImport.error.empty",
                    "relayImport.error.badFormat", "relayImport.error.expired"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
    }
}
