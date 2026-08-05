import XCTest
@testable import CodexRemote

/// #2：全量 diff 缓存以 mode+cwd 复合键失效——切工作区（cwd 变）必重取，同 cwd 不重复取。
final class ReviewFullDiffCacheTests: XCTestCase {
    func test_switchCwd_refetches() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: "/A", currentCwd: "/B"))
    }
    func test_sameCwd_noRefetch() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: "/A", currentCwd: "/A"))
    }
    func test_firstLoad_nilCache_refetches() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: nil, currentCwd: "/A"))
    }
    func test_nilCwd_noRequest() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: nil, currentCwd: nil))
    }
    func test_turnMode_noFullFetch() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .turn, cachedCwd: nil, currentCwd: "/A"))
    }
}
