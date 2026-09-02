import XCTest
@testable import CodexRemote

/// D8：滚动位置感知决策——仅近底时新内容自动滚；远离底部时不滚且提示「新消息」。
final class ConversationScrollAnchorTests: XCTestCase {
    func test_nearBottom_autoScrollsOnNewContent() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: false))
    }
    func test_awayFromBottom_showsNewMessagesAffordance() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: false, contentDidGrow: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: true, contentDidGrow: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: false, contentDidGrow: false))
    }
    func test_nearBottomThreshold() {
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 40, threshold: 120))
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 119, threshold: 120))
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 120, threshold: 120))  // 边界含
        XCTAssertFalse(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 121, threshold: 120))
        XCTAssertFalse(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 400, threshold: 120))
    }
    func test_contentGrowthUsesHeightNotItemCount() {
        XCTAssertTrue(ScrollAnchorPolicy.contentDidGrow(previousHeight: 400, currentHeight: 401))
        XCTAssertFalse(ScrollAnchorPolicy.contentDidGrow(previousHeight: 400, currentHeight: 400.4))
        XCTAssertFalse(ScrollAnchorPolicy.contentDidGrow(previousHeight: 400, currentHeight: 350))
        XCTAssertFalse(ScrollAnchorPolicy.contentDidGrow(previousHeight: 0, currentHeight: 400))
    }
    func test_onlyUserInitiatedScrollUsesAnimation() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldAnimateScroll(userInitiated: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldAnimateScroll(userInitiated: false))
    }

    // MARK: 回到最新浮钮（toolbar-status-and-jump-to-latest §2b）

    func test_jumpToLatest_showsOnlyWhenAwayFromBottom() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldShowJumpToLatest(isNearBottom: false))
        XCTAssertFalse(ScrollAnchorPolicy.shouldShowJumpToLatest(isNearBottom: true))
    }

    /// 合成优先级：新消息文案态 > 纯 ↓ 图标态 > 隐藏（design §2b 定案）。
    func test_jumpAffordance_priorityAndHiding() {
        XCTAssertEqual(ScrollAnchorPolicy.jumpAffordance(showNewBelow: true, isNearBottom: false),
                       .newMessages, "离底+新消息 → 文案态优先")
        XCTAssertEqual(ScrollAnchorPolicy.jumpAffordance(showNewBelow: false, isNearBottom: false),
                       .jumpToLatest, "仅离底无新消息 → 纯 ↓ 图标态")
        XCTAssertEqual(ScrollAnchorPolicy.jumpAffordance(showNewBelow: false, isNearBottom: true),
                       .hidden, "贴底 → 隐藏")
        // showNewBelow=true 的显示条件保持既有语义（贴底瞬间由 preference 回流复位 showNewBelow，
        // 合成函数不额外压制）——showNewBelow 行为零回归锁。
        XCTAssertEqual(ScrollAnchorPolicy.jumpAffordance(showNewBelow: true, isNearBottom: true),
                       .newMessages)
    }

    /// 进会话初始定位到最新（spec 场景）：仅 loaded 触发一次性回底；loading/failed/idle 不触发。
    func test_snapToLatestOnLoad_onlyWhenLoaded() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldSnapToLatest(loadState: .loaded))
        XCTAssertFalse(ScrollAnchorPolicy.shouldSnapToLatest(loadState: .loading))
        XCTAssertFalse(ScrollAnchorPolicy.shouldSnapToLatest(loadState: .failed))
        XCTAssertFalse(ScrollAnchorPolicy.shouldSnapToLatest(loadState: .idle))
        XCTAssertFalse(ScrollAnchorPolicy.shouldSnapToLatest(loadState: nil))
    }
}
