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

    @MainActor @Test func subscribesBeforeInitialSnapshotCompletes() async {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        let attach = Task { await store.attach(rpc: rpc) }

        guard let firstID = await requestID(mock, ordinal: 0) else {
            Issue.record("initial skills snapshot was not requested"); attach.cancel(); return
        }
        await mock.feed(#"{"method":"skills/changed"}"#)
        await mock.feed(#"{"id":"\#(firstID)","result":{"data":[{"cwd":"/","errors":[],"skills":[{"name":"old","path":"/old","enabled":true,"scope":"user"}]}]}}"#)

        guard let secondID = await requestID(mock, ordinal: 1) else {
            Issue.record("skills notification in snapshot window did not trigger refresh"); attach.cancel(); return
        }
        await mock.feed(#"{"id":"\#(secondID)","result":{"data":[{"cwd":"/","errors":[],"skills":[{"name":"new","path":"/new","enabled":true,"scope":"user"}]}]}}"#)
        await attach.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.skills.map(\.name) == ["new"])
    }

    private func requestID(_ mock: MockTransport, ordinal: Int) async -> String? {
        for _ in 0..<200 {
            let ids = await mock.sent.compactMap { frame -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      object["method"] as? String == RPCMethod.skillsList else { return nil }
                return object["id"] as? String
            }
            if ids.indices.contains(ordinal) { return ids[ordinal] }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
