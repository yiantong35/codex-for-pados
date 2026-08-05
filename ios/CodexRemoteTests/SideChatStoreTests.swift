import Testing
import Foundation
@testable import CodexRemote

@MainActor
struct SideChatStoreTests {

    private func makeStore() async -> (MockTransport, JSONRPCClient, SideChatStore) {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = SideChatStore()
        store.attach(rpc: rpc)
        return (mock, rpc, store)
    }

    private func respondFork(_ mock: MockTransport) -> Task<Void, Never> {
        Task {
            var answered = Set<String>()
            var seq = 0
            for _ in 0..<800 {
                if Task.isCancelled { return }
                for frame in await mock.sent {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = obj["id"] as? String,
                          obj["method"] as? String == RPCMethod.threadFork,
                          !answered.contains(id) else { continue }
                    answered.insert(id)
                    let from = ((obj["params"] as? [String: Any])?["threadId"] as? String) ?? "?"
                    seq += 1
                    let newId = "fork-\(seq)"
                    await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"thread":{"id":"\#(newId)","forkedFromId":"\#(from)","ephemeral":true}}}"#)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // #4 手动重连重绑：侧聊会话内嵌的 ConversationStore 持旧 rpc（`let`）+ 旧 threadId 订阅。
    // 完整重连（新 rpc 实例）后旧会话全打向已关闭 client、订阅绑死旧流 → 应在 attach 新 rpc 时
    // 清空 stale 侧聊（fail-closed：不留半死会话；用户可在新连接上重新 fork）。
    @Test func reattachNewRpcClearsStaleSessions() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 1)

        let mockB = MockTransport()
        let rpcB = JSONRPCClient(transport: mockB)
        await rpcB.start()
        store.attach(rpc: rpcB)   // 模拟完整重连：新 rpc 实例

        #expect(store.sessions.isEmpty)     // stale 侧聊被清
        #expect(store.selectedId == nil)
    }

    @Test func startAddsAndSelectsSession() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.conversation.threadId == "fork-1")
        #expect(store.selectedId == store.sessions.first?.id)
    }

    @Test func multipleStartsAreIndependent() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 2)
        let tids = Set(store.sessions.map { $0.conversation.threadId })
        #expect(tids == ["fork-1", "fork-2"])
    }

    @Test func closeRemovesAndReselects() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        let selected = store.selectedId!
        store.close(id: selected)
        #expect(store.sessions.count == 1)
        #expect(store.selectedId == store.sessions.first?.id)
    }

    @Test func closeLastClearsSelection() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        store.close(id: store.selectedId!)
        #expect(store.sessions.isEmpty)
        #expect(store.selectedId == nil)
    }

    @Test func noMainThreadDoesNotFork() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.sessions.isEmpty)
        let forkCount = await mock.sent.filter { $0.contains(RPCMethod.threadFork) }.count
        #expect(forkCount == 0)
    }

    @Test func noRpcDoesNotFork() async {
        let store = SideChatStore()
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.isEmpty)
    }

    @Test func streamIsolatedByThreadId() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"fork-1","turn":{"id":"T1","status":"inProgress"}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"fork-1","item":{"id":"I1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"fork-1","itemId":"I1","delta":"only-1"}}"#)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let s1 = store.sessions.first { $0.conversation.threadId == "fork-1" }!
        let s2 = store.sessions.first { $0.conversation.threadId == "fork-2" }!
        #expect(!s1.conversation.state.items.isEmpty)
        #expect(s2.conversation.state.items.isEmpty)
    }
}
