import XCTest
@testable import CodexRemote

final class TransportControlTests: XCTestCase {
    // 默认实现：未覆写 control() 的 transport 返回一个立即结束的空流（不挂起）。
    func testDefaultControlStreamFinishesImmediately() async {
        let mock = MockTransport()
        var count = 0
        for await _ in mock.control() { count += 1 }
        XCTAssertEqual(count, 0)
    }

    // 控制事件枚举可比较（ConnectionStore 据此分支）。
    func testControlEventEquatable() {
        XCTAssertEqual(TransportControlEvent.reconnecting, .reconnecting)
        XCTAssertNotEqual(TransportControlEvent.reconnecting, .ready)
    }
}
