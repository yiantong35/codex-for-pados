import XCTest
@testable import CodexRemote

/// #1 剪贴板写门控：策略纯逻辑单测。
/// 参照 SettingsSectionViewLogicTests 的注入式 UserDefaults 隔离写法，避免污染 .standard。
@MainActor
final class ClipboardPolicyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClipboardPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    func testDefaultIsOffSoNeverWrites() {
        let p = ClipboardPolicyStore(store: defaults)
        XCTAssertFalse(p.allowRemoteWrite)                 // 默认关闭
        XCTAssertFalse(p.shouldWrite(byteCount: 1))        // 关 → 一律拒写
    }

    func testOnAndWithinLimitWrites() {
        let p = ClipboardPolicyStore(store: defaults)
        p.allowRemoteWrite = true
        XCTAssertTrue(p.shouldWrite(byteCount: 64 * 1024))       // 恰好上限内
        XCTAssertFalse(p.shouldWrite(byteCount: 64 * 1024 + 1))  // 超一字节拒写
    }

    func testTogglePersists() {
        let p = ClipboardPolicyStore(store: defaults)
        p.allowRemoteWrite = true
        XCTAssertTrue(ClipboardPolicyStore(store: defaults).allowRemoteWrite)  // 重建仍为 true
    }
}
