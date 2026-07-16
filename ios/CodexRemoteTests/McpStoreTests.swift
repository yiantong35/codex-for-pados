import Testing
import Foundation
@testable import CodexRemote

struct McpStoreTests {
    // attach 触发 refresh → 发出 mcpServerStatus/list 帧
    @MainActor @Test func attachSendsListFrame() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = McpStore()
        await store.attach(rpc: rpc)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("mcpServerStatus/list") })
    }

    // reload() 发出 config/mcpServer/reload 帧
    @MainActor @Test func reloadSendsReloadFrame() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = McpStore()
        await store.attach(rpc: rpc)
        await store.reload()
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("config/mcpServer/reload") })
    }

    // 未连接（未 attach，rpc == nil）→ refresh 不发请求、servers 保持空、不崩
    @MainActor @Test func refreshWithoutRpcIsNoOp() async {
        let store = McpStore()
        await store.refresh()
        #expect(store.servers.isEmpty)
    }

    // 完整重连（rpc 实例更换）后，应对 newRpc 重新订阅通知：
    // attach(rpcA) → attach(rpcB) → 经 rpcB 真实通知流投递 mcpServer/startupStatus/updated
    // → 断言在 rpcB(mockB) 上再次发出 mcpServerStatus/list（重订阅生效）。
    @MainActor @Test func reSubscribesOnRpcChange() async throws {
        let mockA = MockTransport()
        await mockA.setAutoRespond(true)
        let rpcA = JSONRPCClient(transport: mockA)
        await rpcA.start()

        let mockB = MockTransport()
        await mockB.setAutoRespond(true)
        let rpcB = JSONRPCClient(transport: mockB)
        await rpcB.start()

        let store = McpStore()
        await store.attach(rpc: rpcA)
        await store.attach(rpc: rpcB)   // 模拟完整重连：新 rpc 实例

        // attach(rpcB) 的 refresh 已在 mockB 发一次 list；清点后经 rpcB 真实流喂通知，应再发一次
        let before = await mockB.sent.filter { $0.contains("mcpServerStatus/list") }.count
        await mockB.feed(#"{"method":"mcpServer/startupStatus/updated"}"#)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await mockB.sent.filter { $0.contains("mcpServerStatus/list") }.count
        #expect(after > before)
    }

    // 收到 McpServerStatusUpdated 通知 → 触发 refresh（再次发出 list 帧）
    @MainActor @Test func broadcastTriggersRefresh() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = McpStore()
        await store.attach(rpc: rpc)
        // attach 已发一次 list；清点后手动喂通知，应再发一次
        let before = await mock.sent.filter { $0.contains("mcpServerStatus/list") }.count
        store.applyBroadcast(JSONRPCNotification(method: ServerNotificationMethod.mcpServerStatusUpdated, params: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let after = await mock.sent.filter { $0.contains("mcpServerStatus/list") }.count
        #expect(after > before)
    }
}
