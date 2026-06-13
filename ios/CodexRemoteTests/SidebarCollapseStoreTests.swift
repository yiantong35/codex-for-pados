import XCTest
@testable import CodexRemote

final class SidebarCollapseStoreTests: XCTestCase {
    func test_collapse_roundtrip_persists() {
        let suite = "test.sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SidebarCollapseStore(defaults: defaults)
        XCTAssertFalse(store.isCollapsed("proj-1"))     // 默认展开
        store.setCollapsed("proj-1", true)
        XCTAssertTrue(store.isCollapsed("proj-1"))
        // 新实例从同一 defaults 读 → 持久化生效
        let reloaded = SidebarCollapseStore(defaults: defaults)
        XCTAssertTrue(reloaded.isCollapsed("proj-1"))
        defaults.removePersistentDomain(forName: suite)
    }
}
