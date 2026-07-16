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
