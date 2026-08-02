import XCTest
@testable import CodexRemote

/// 任务 10：SSH/ProxyChannel 掉线可见。
/// 非主动掉线（exec 意外结束 → finishIncoming）发 `.connectionFailed`；
/// 用户主动 `close()` 静默（activeClose 区分）。不做自动重连。
final class ProxyChannelControlTests: XCTestCase {

    /// 意外掉线：exec 非主动结束 → control() 发 .connectionFailed（→ ConnectionStore phase .failed）。
    func test_unexpectedExit_emitsConnectionFailed() async throws {
        let ch = ProxyChannel.makeForTesting()
        var ctrl = ch.control().makeAsyncIterator()

        // 模拟子进程意外退出（非主动 close）：直接驱动非主动掉线路径。
        await ch.finishIncomingForTesting(nil)

        let ev = await ctrl.next()
        XCTAssertEqual(ev, .connectionFailed)
    }

    /// 主动关闭：activeClose 置位 → 不发 .connectionFailed，control 流 finish。
    /// 即便 close 后 execTask 取消致 withExec 返回再触发 finishIncoming，也保持静默。
    func test_activeClose_doesNotEmitFailed() async throws {
        let ch = ProxyChannel.makeForTesting()
        var ctrl = ch.control().makeAsyncIterator()

        await ch.close()                        // 用户主动断开 → 静默 + finish 流
        await ch.finishIncomingForTesting(nil)  // 复现 close 后 withExec 返回触发 finishIncoming

        // 主动关闭：control 流应 finish（next=nil），且绝不含 .connectionFailed。
        let ev = await ctrl.next()
        XCTAssertNil(ev)
    }
}
