import XCTest
@testable import CodexRemote

/// #10：半开连接（response 永不到）下 `JSONRPCClient.send` 必须可取消。
/// 旧实现 `withCheckedThrowingContinuation` 无取消处理 → 取消外层 Task 唤不醒 continuation →
/// 心跳探针 `withTaskGroup` 隐式 await 所有子任务 → 探针永久挂起，10s 超时形同虚设。
/// 修复后：取消时移除对应 pending 并以 `CancellationError` resume（同构 failPending）。
final class JSONRPCClientCancellationTests: XCTestCase {

    /// 记录探针结局的收集器（避免结构化 await 挂起中的探针 Task 本身）。
    private actor Outcome {
        enum State { case pending, cancelled, other(String) }
        private(set) var state: State = .pending
        func settle(_ s: State) { if case .pending = state { state = s } }
        var settled: Bool { if case .pending = state { return false }; return true }
    }

    /// 请求发出后无回响，取消其 Task → send 应及时抛错解挂，而非永久挂起。
    func test_cancelled_send_unblocks_promptly_on_half_open() async throws {
        let mock = MockTransport()   // 不 autoRespond：response 永不到（半开连接）
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let empty = try JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))

        let outcome = Outcome()
        let probe = Task {
            do {
                _ = try await client.send(method: RPCMethod.getAuthStatus, params: empty)
                await outcome.settle(.other("returned without error"))
            } catch is CancellationError {
                await outcome.settle(.cancelled)
            } catch {
                await outcome.settle(.other(String(describing: error)))
            }
        }
        // 等 send 真正登记进 pending（帧已发出）后再取消，确保取消命中挂起中的 continuation。
        try await waitUntil { await !mock.sent.isEmpty }
        probe.cancel()

        // 有界轮询结局：绝不 await probe.value（若挂起会拖死本测试）。
        try await waitUntil(timeout: 2) { await outcome.settled }
        let state = await outcome.state
        switch state {
        case .cancelled:
            break   // 期望：取消以 CancellationError 解挂
        case .pending:
            XCTFail("取消后 send 仍挂起（半开连接下不可取消）")
        case .other(let d):
            XCTFail("取消应以 CancellationError 解挂，实际=\(d)")
        }
        probe.cancel()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // 超时不 XCTFail（调用点自行判定 settled 状态），只返回。
    }
}
