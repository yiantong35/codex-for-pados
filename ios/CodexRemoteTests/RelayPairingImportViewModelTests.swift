import XCTest
import SwiftUI
import RelayProtocol
@testable import CodexRemote

@MainActor
final class RelayPairingImportViewModelTests: XCTestCase {
    func testValidPasteParsesToMachineConfig() throws {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=9999999999"
        let (cfg, pc) = try vm.makeMachineConfig(now: 1)
        // 5.4：断言 relay 结构化三字段非空，pc 单独非空返回（不进 config）。
        XCTAssertFalse(cfg.relayURL.isEmpty)
        XCTAssertFalse(cfg.sessionId.isEmpty)
        XCTAssertFalse(cfg.devIdentityPubB64.isEmpty)
        XCTAssertFalse(pc.isEmpty)
    }

    func testRePairPreservesMachineIdentityAndDisplayName() throws {
        let existing = MachineConfig(
            displayName: "My Mac", relayURL: "wss://old.example/ws",
            sessionId: "old", devIdentityPubB64: "OLD")
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://new.example/ws&sid=new&pk=NEW&pc=c&exp=9999999999"

        let (config, _) = try vm.makeMachineConfig(now: 1, replacing: existing)

        XCTAssertEqual(config.id, existing.id)
        XCTAssertEqual(config.displayName, existing.displayName)
        XCTAssertEqual(config.sessionId, "new")
    }

    /// 6.2：非 loopback 明文 ws 导入即报 insecureScheme（早报错，不等到连接时才失败）。
    func testImportRejectsPlainWsWithSchemeError() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=ws://relay.example/ws&sid=s&pk=PUB&pc=C&exp=9999999999"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 0)) { error in
            XCTAssertEqual(error as? PairingImportError, .insecureScheme)
        }
    }

    /// 5.4：配对成功后走 MachineStore.add 持久化一遍，磁盘原始字节绝不含配对码（pc）。
    /// 配对码只应经 PendingPairingStore（内存）流转，绝不落 UserDefaults。
    func testPersistedMachinesNeverContainPairingCode() throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = MachineStore(defaults: defaults)
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://r.example/ws&sid=s&pk=PUB&pc=TOPSECRET&exp=9999999999"
        let (config, pc) = try vm.makeMachineConfig(now: 0)
        XCTAssertEqual(pc, "TOPSECRET")

        _ = store.add(config)   // 持久化

        let raw = String(decoding: defaults.data(forKey: "machines") ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains("TOPSECRET"), "持久化字节不应含配对码原文")
        XCTAssertFalse(raw.contains("pc="), "持久化字节不应含 pc= 标记")
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

    // MARK: - 扫码结果 = 字符串后的逻辑（与手动粘贴同路径；相机本身不单测）

    /// 扫到合法二维码字符串写入 vm.pasted → makeMachineConfig 成功返回 .relay。
    func testScannedValidPayloadParsesToMachineConfig() throws {
        let vm = RelayPairingImportViewModel()
        // 模拟 QRScannerView.onScan 回调把扫得的字符串交给 vm.pasted。
        let scanned = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=9999999999"
        vm.pasted = scanned
        let (cfg, _) = try vm.makeMachineConfig(now: 1)
        XCTAssertFalse(cfg.relayURL.isEmpty, "扫码解析应产出非空 relay 载荷")
    }

    /// 扫到过期二维码字符串 → makeMachineConfig 抛 .expired。
    func testScannedExpiredPayloadRejected() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=1000"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 2000)) { error in
            XCTAssertEqual(error as? PairingImportError, .expired)
        }
    }

    /// 扫到非法（非配对串）二维码 → makeMachineConfig 抛 .badFormat（明确错误）。
    func testScannedGarbagePayloadRejected() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "https://example.com/not-a-pairing"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 1)) { error in
            XCTAssertEqual(error as? PairingImportError, .badFormat)
        }
    }

    /// 扫码相关本地化键须可解析（扫码按钮 + 相机权限/不可用回退文案）。
    func test_relayImport_scanLocalizationKeys_present() {
        for key in ["relayImport.scan", "relayImport.error.cameraDenied",
                    "relayImport.error.cameraUnavailable"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
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
            PerceptualSnapshot.assert(png, named: name)
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
                    "relayImport.error.badFormat", "relayImport.error.expired",
                    "relayImport.error.insecureScheme"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
    }
}
