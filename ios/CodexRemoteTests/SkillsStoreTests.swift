import Testing
import Foundation
@testable import CodexRemote

struct SkillsStoreTests {
    // attach 触发 refresh → 发出 skills/list 帧
    @MainActor @Test func attachSendsListFrame() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        await store.attach(rpc: rpc)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("skills/list") })
    }

    // setEnabled 发出 skills/config/write 帧（且随后 refresh 再发 skills/list）
    @MainActor @Test func setEnabledSendsConfigWrite() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        await store.attach(rpc: rpc)
        await store.setEnabled(name: "fmt", path: nil, false)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("skills/config/write") })
    }

    // 未连接（未 attach，rpc == nil）→ refresh 不发请求、skills 空、不崩
    @MainActor @Test func refreshWithoutRpcIsNoOp() async {
        let store = SkillsStore()
        await store.refresh()
        #expect(store.skills.isEmpty)
    }

    // skills/changed 通知 → 触发 refresh（再次发出 list 帧）
    @MainActor @Test func broadcastTriggersRefresh() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        await store.attach(rpc: rpc)
        let before = await mock.sent.filter { $0.contains("skills/list") }.count
        store.applyBroadcast(JSONRPCNotification(method: ServerNotificationMethod.skillsChanged, params: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let after = await mock.sent.filter { $0.contains("skills/list") }.count
        #expect(after > before)
    }

    // 完整重连（rpc 实例更换）后对 newRpc 重新订阅 skills/changed
    @MainActor @Test func reSubscribesOnRpcChange() async {
        let mockA = MockTransport(); await mockA.setAutoRespond(true)
        let rpcA = JSONRPCClient(transport: mockA); await rpcA.start()
        let mockB = MockTransport(); await mockB.setAutoRespond(true)
        let rpcB = JSONRPCClient(transport: mockB); await rpcB.start()
        let store = SkillsStore()
        await store.attach(rpc: rpcA)
        await store.attach(rpc: rpcB)   // 模拟完整重连：新 rpc 实例
        let before = await mockB.sent.filter { $0.contains("skills/list") }.count
        await mockB.feed(#"{"method":"skills/changed"}"#)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await mockB.sent.filter { $0.contains("skills/list") }.count
        #expect(after > before)
    }
}
