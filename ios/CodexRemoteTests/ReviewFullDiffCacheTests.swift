import XCTest
@testable import CodexRemote

/// #2：全量 diff 缓存以 mode+cwd 复合键失效——切工作区（cwd 变）必重取，同 cwd 不重复取。
final class ReviewFullDiffCacheTests: XCTestCase {
    @MainActor
    func test_sameContextExplicitRefreshChangesSnapshot() async {
        let model = FullDiffSnapshotModel()
        let context = FullDiffContextKey(cwd: "/A", conversationIdentity: "thread|rpc")
        var values = ["first", "second"]
        _ = await model.refresh(context: context) { _ in values.removeFirst() }
        XCTAssertEqual(model.diff, "first")
        _ = await model.refresh(context: context) { _ in values.removeFirst() }
        XCTAssertEqual(model.diff, "second")
    }

    @MainActor
    func test_contextChangeClearsImmediatelyAndOldCompletionCannotOverwrite() async {
        let model = FullDiffSnapshotModel()
        let old = FullDiffContextKey(cwd: "/same", conversationIdentity: "old-thread|old-rpc")
        let new = FullDiffContextKey(cwd: "/same", conversationIdentity: "new-thread|new-rpc")
        let oldTask = Task {
            await model.refresh(context: old) { _ in
                try? await Task.sleep(nanoseconds: 80_000_000)
                return "old"
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        model.invalidate(for: new)
        XCTAssertNil(model.diff)
        let newResult = await model.refresh(context: new) { _ in "new" }
        XCTAssertTrue(newResult)
        _ = await oldTask.value
        XCTAssertEqual(model.context, new)
        XCTAssertEqual(model.diff, "new")
    }
    func test_switchCwd_refetches() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: "/A", currentCwd: "/B"))
    }
    func test_sameCwd_noRefetch() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(
            mode: .full, cachedCwd: "/A", currentCwd: "/A",
            cachedGeneration: 2, currentGeneration: 2))
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
    func test_newFetchGeneration_refetchesSameCwd() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(
            mode: .full, cachedCwd: "/A", currentCwd: "/A",
            cachedGeneration: 1, currentGeneration: 2))
    }
}
