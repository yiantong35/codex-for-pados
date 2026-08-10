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

    @MainActor @Test func toggleIsOptimisticAndRejectsConcurrentWrites() async {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        let attach = Task { await store.attach(rpc: rpc) }

        guard let listID = await requestID(mock, method: RPCMethod.skillsList, ordinal: 0) else {
            Issue.record("initial skills snapshot was not requested"); return
        }
        await mock.feed(#"{"id":"\#(listID)","result":{"data":[{"cwd":"/","errors":[],"skills":[{"name":"fmt","path":"/fmt","enabled":false,"scope":"user"}]}]}}"#)
        await attach.value

        let first = Task { await store.setEnabled(name: nil, path: "/fmt", true) }
        for _ in 0..<100 where !store.isUpdating("/fmt") { await Task.yield() }
        #expect(store.skills.first?.enabled == true)
        #expect(store.isUpdating("/fmt"))

        await store.setEnabled(name: nil, path: "/fmt", false)
        guard let writeID = await requestID(
            mock, method: RPCMethod.skillsConfigWrite, ordinal: 0
        ) else { Issue.record("write was not requested"); return }
        let writeIDs = await requestIDs(mock, method: RPCMethod.skillsConfigWrite)
        #expect(writeIDs.count == 1)

        await mock.feed(#"{"id":"\#(writeID)","result":{}}"#)
        guard let refreshID = await requestID(mock, method: RPCMethod.skillsList, ordinal: 1) else {
            Issue.record("post-write refresh was not requested"); return
        }
        await mock.feed(#"{"id":"\#(refreshID)","result":{"data":[{"cwd":"/","errors":[],"skills":[{"name":"fmt","path":"/fmt","enabled":true,"scope":"user"}]}]}}"#)
        await first.value
        #expect(!store.isUpdating("/fmt"))
        #expect(store.skills.first?.enabled == true)
    }

    @MainActor @Test func failedToggleRollsBackOnlyTheSkill() async {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SkillsStore()
        let attach = Task { await store.attach(rpc: rpc) }

        guard let listID = await requestID(mock, method: RPCMethod.skillsList, ordinal: 0) else {
            Issue.record("initial skills snapshot was not requested"); return
        }
        await mock.feed(#"{"id":"\#(listID)","result":{"data":[{"cwd":"/","errors":[],"skills":[{"name":"fmt","path":"/fmt","enabled":false,"scope":"user"}]}]}}"#)
        await attach.value

        let toggle = Task { await store.setEnabled(name: nil, path: "/fmt", true) }
        guard let writeID = await requestID(mock, method: RPCMethod.skillsConfigWrite, ordinal: 0) else {
            Issue.record("write was not requested"); return
        }
        #expect(store.skills.first?.enabled == true)
        await mock.feed(#"{"id":"\#(writeID)","error":{"code":-32000,"message":"internal"}}"#)
        await toggle.value

        #expect(store.skills.first?.enabled == false)
        #expect(store.writeFailed("/fmt"))
        #expect(store.loadState == .loaded)
    }

    private func requestID(_ mock: MockTransport, method: String = RPCMethod.skillsList,
                           ordinal: Int) async -> String? {
        for _ in 0..<200 {
            let ids = await requestIDs(mock, method: method)
            if ids.indices.contains(ordinal) { return ids[ordinal] }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    private func requestIDs(_ mock: MockTransport, method: String) async -> [String] {
        await mock.sent.compactMap { frame -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                  object["method"] as? String == method else { return nil }
            return object["id"] as? String
        }
    }
}
