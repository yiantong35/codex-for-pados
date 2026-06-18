import XCTest
@testable import CodexRemote

@MainActor
final class ReadStateStoreTests: XCTestCase {

    /// 每个测试用独立 suite 名的 UserDefaults，互不污染。
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // B2：首次空 map → 全部已读（viewedAt 视为 +∞ 行为：任何 outcome 都不算未读）
    func test_empty_store_treats_all_as_viewed() {
        let store = ReadStateStore(defaults: makeDefaults())
        // 没记录过 viewedAt → viewedAt(id) 返回 .infinity，使 updatedAt > viewedAt 恒 false
        XCTAssertEqual(store.viewedAt("t1"), .infinity)
        XCTAssertNil(store.lastOutcome("t1"))
    }

    func test_markViewed_records_updatedAt() {
        let store = ReadStateStore(defaults: makeDefaults())
        store.markViewed("t1", updatedAt: 123.0)
        XCTAssertEqual(store.viewedAt("t1"), 123.0)
    }

    func test_recordOutcome_then_read() {
        let store = ReadStateStore(defaults: makeDefaults())
        store.recordOutcome("t1", outcome: .failed)
        XCTAssertEqual(store.lastOutcome("t1"), .failed)
    }

    // B8：失败后重跑成功 → outcome 覆盖为 completed
    func test_recordOutcome_overwrites() {
        let store = ReadStateStore(defaults: makeDefaults())
        store.recordOutcome("t1", outcome: .failed)
        store.recordOutcome("t1", outcome: .completed)
        XCTAssertEqual(store.lastOutcome("t1"), .completed)
    }

    // 重启场景：同 suite 重新构造 store，数据仍在（UserDefaults 往返）
    func test_persists_across_reinit() {
        let name = "readstate.persist.\(UUID().uuidString)"
        let d1 = makeDefaults(name)
        let s1 = ReadStateStore(defaults: d1)
        s1.markViewed("t1", updatedAt: 50)
        s1.recordOutcome("t1", outcome: .completed)

        // 模拟重启：用同名 suite 重新读取
        let d2 = UserDefaults(suiteName: name)!
        let s2 = ReadStateStore(defaults: d2)
        XCTAssertEqual(s2.viewedAt("t1"), 50)
        XCTAssertEqual(s2.lastOutcome("t1"), .completed)
        d2.removePersistentDomain(forName: name)
    }
}
