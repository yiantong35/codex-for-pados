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
        try? await Task.sleep(nanoseconds: 350_000_000)
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
        try? await Task.sleep(nanoseconds: 350_000_000)
        let after = await mock.sent.filter { $0.contains("mcpServerStatus/list") }.count
        #expect(after > before)
    }

    @MainActor @Test func burstNotificationsCoalesceIntoOneRefresh() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = McpStore()
        await store.attach(rpc: rpc)

        let before = await mock.sent.filter { $0.contains("mcpServerStatus/list") }.count
        for _ in 0..<8 {
            store.applyBroadcast(JSONRPCNotification(
                method: ServerNotificationMethod.mcpServerStatusUpdated,
                params: nil
            ))
        }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let after = await mock.sent.filter { $0.contains("mcpServerStatus/list") }.count
        #expect(after == before + 1)
    }

    @MainActor @Test func rpcChangeCancelsPendingNotificationRefresh() async throws {
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

        store.applyBroadcast(JSONRPCNotification(
            method: ServerNotificationMethod.mcpServerStatusUpdated,
            params: nil
        ))
        let beforeA = await mockA.sent.filter { $0.contains("mcpServerStatus/list") }.count
        await store.attach(rpc: rpcB)
        try? await Task.sleep(nanoseconds: 350_000_000)

        let afterA = await mockA.sent.filter { $0.contains("mcpServerStatus/list") }.count
        #expect(afterA == beforeA)
        #expect(await mockB.sent.filter { $0.contains("mcpServerStatus/list") }.count == 1)
    }

    @MainActor @Test func subscribesBeforeInitialSnapshotCompletes() async {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = McpStore()
        let attach = Task { await store.attach(rpc: rpc) }

        guard let firstID = await requestID(mock, method: RPCMethod.mcpServerStatusList, ordinal: 0) else {
            Issue.record("initial MCP snapshot was not requested"); attach.cancel(); return
        }
        await mock.feed(#"{"method":"mcpServer/startupStatus/updated"}"#)
        await mock.feed(#"{"id":"\#(firstID)","result":{"data":[{"name":"old"}]}}"#)

        guard let secondID = await requestID(mock, method: RPCMethod.mcpServerStatusList, ordinal: 1) else {
            Issue.record("notification in snapshot window did not trigger refresh"); attach.cancel(); return
        }
        await mock.feed(#"{"id":"\#(secondID)","result":{"data":[{"name":"new"}]}}"#)
        await attach.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.servers.map(\.name) == ["new"])
    }

    private func requestID(_ mock: MockTransport, method: String, ordinal: Int) async -> String? {
        for _ in 0..<200 {
            let ids = await mock.sent.compactMap { frame -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      object["method"] as? String == method else { return nil }
                return object["id"] as? String
            }
            if ids.indices.contains(ordinal) { return ids[ordinal] }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
