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
}
