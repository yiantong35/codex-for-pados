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

    @Test func reattachNewRpcKeepsMetadataForVisibleViewToResume() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 1)

        let mockB = MockTransport()
        let rpcB = JSONRPCClient(transport: mockB)
        await rpcB.start()
        store.attach(rpc: rpcB)   // 模拟完整重连：新 rpc 实例

        #expect(store.sessions.map(\.id) == ["fork-1"])
        #expect(store.selectedId == "fork-1")
    }

    @Test func startAddsAndSelectsSession() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == "fork-1")
        #expect(store.sessions.first?.forkedFromId == "main-1")
        #expect(store.selectedId == store.sessions.first?.id)
    }

    @Test func multipleStartsAreIndependent() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        #expect(store.sessions.count == 2)
        let tids = Set(store.sessions.map(\.id))
        #expect(tids == ["fork-1", "fork-2"])
    }

    @Test func closeRemovesAndReselects() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        let selected = store.selectedId!
        #expect(await store.close(id: selected))
        #expect(store.sessions.count == 1)
        #expect(store.selectedId == store.sessions.first?.id)
    }

    @Test func closeLastClearsSelection() async {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        #expect(await store.close(id: store.selectedId!))
        #expect(store.sessions.isEmpty)
        #expect(store.selectedId == nil)
    }

    @Test func closeClearsDraftAndReleasesQueuedPayload() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let drafts = ComposerDraftStore()
        let registry = ConversationOutboxRegistry()
        let store = SideChatStore(draftStore: drafts, conversationOutboxes: registry)
        store.attach(rpc: rpc)
        let responder = respondFork(mock); defer { responder.cancel() }
        await store.start(fromThreadId: "main-1")
        let id = try #require(store.selectedId)
        let oldDraft = drafts.draft(for: id)
        oldDraft.text = "discard me"
        oldDraft.imageAttachment.load {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return Data([0x01])
        }
        #expect(oldDraft.imageAttachment.hasActiveTaskForTesting)
        let outbox = registry.outbox(for: id)
        _ = try outbox.enqueue(input: [.text("queued")], model: nil, effort: nil)

        #expect(await store.close(id: id))

        #expect(oldDraft.text.isEmpty)
        #expect(!oldDraft.imageAttachment.hasActiveTaskForTesting)
        #expect(drafts.draftCountForTesting == 0)
        #expect(outbox.entries.isEmpty)
        #expect(drafts.draft(for: id) !== oldDraft)
    }

    @Test func sideChatContentIdentityFollowsThread() {
        let first = SideChatSession(id: "a", forkedFromId: nil, title: "A")
        let second = SideChatSession(id: "b", forkedFromId: nil, title: "B")
        #expect(SideChatView.contentIdentity(for: first) != SideChatView.contentIdentity(for: second))
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

    @Test func metadataStoreCreatesNoNotificationSubscribers() async {
        let (mock, rpc, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        #expect(await rpc.liveNotificationSubscriberCount() == 0)
    }

    @Test func runningSessionRequiresInterruptAndCloseSendsInterrupt() async throws {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        let id = try #require(store.selectedId)
        let conversation = try #require(store.conversationStore(for: id))
        await conversation.startObserving()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"fork-1","turn":{"id":"T1","status":"inProgress"}}}"#)
        for _ in 0..<100 where !conversation.state.isTurnRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(store.isRunning(id: id))

        let rejected = await store.close(id: id)
        #expect(!rejected)
        #expect(store.sessions.count == 1)

        await mock.setAutoRespond(true)
        #expect(await store.close(id: id, interruptIfRunning: true))
        #expect(store.sessions.isEmpty)
        #expect(await mock.sent.contains { $0.contains(RPCMethod.turnInterrupt) })
    }

    @Test func closeClearsThreadOutbox() async throws {
        let (mock, _, store) = await makeStore()
        let r = respondFork(mock); defer { r.cancel() }
        await store.start(fromThreadId: "main-1")
        let id = try #require(store.selectedId)
        let conversation = try #require(store.conversationStore(for: id))
        conversation.isReady = { false }
        await conversation.send(input: [.text("pending")], model: nil, effort: nil)
        #expect(conversation.outbox.count == 1)

        #expect(await store.close(id: id))
        #expect(store.conversationOutboxes.outbox(for: id).entries.isEmpty)
    }

    @Test func switchingReleasesHiddenConversationStore() async throws {
        let (mock, _, store) = await makeStore()
        let responder = respondFork(mock); defer { responder.cancel() }
        await store.start(fromThreadId: "main-1")
        await store.start(fromThreadId: "main-1")
        let ids = store.sessions.map(\.id)
        let second = try #require(store.conversationStore(for: ids[1]))

        store.selectedId = ids[0]
        _ = try #require(store.conversationStore(for: ids[0]))
        store.selectedId = ids[1]
        let rebuiltSecond = try #require(store.conversationStore(for: ids[1]))

        #expect(second !== rebuiltSecond)
    }
}
