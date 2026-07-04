import Testing
import Foundation
@testable import CodexRemote

struct ForkEphemeralTests {
    @Test func encodesEphemeralTrue() throws {
        let params = ThreadForkParams(threadId: "t1", ephemeral: true)
        let json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        #expect(json.contains("\"threadId\":\"t1\""))
        #expect(json.contains("\"ephemeral\":true"))
    }
    @Test func omitsEphemeralWhenNil() throws {
        let params = ThreadForkParams(threadId: "t1", ephemeral: nil)
        let json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        #expect(!json.contains("ephemeral"))
    }
    @Test func decodesForkedFromId() throws {
        let respJSON = #"{"thread":{"id":"fork-1","forkedFromId":"t1","ephemeral":true}}"#
        let decoded = try JSONDecoder().decode(ForkedThreadResponse.self, from: Data(respJSON.utf8))
        #expect(decoded.thread.id == "fork-1")
        #expect(decoded.thread.forkedFromId == "t1")
    }
}

@MainActor
struct ConversationStoreForkTests {
    private func makeStore() async -> (MockTransport, ConversationStore) {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        return (mock, ConversationStore(rpc: rpc, threadId: "t1"))
    }
    private func respondFork(_ mock: MockTransport, newId: String, from: String) -> Task<Void, Never> {
        Task {
            var answered = Set<String>()
            for _ in 0..<400 {
                if Task.isCancelled { return }
                for frame in await mock.sent {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = obj["id"] as? String,
                          obj["method"] as? String == RPCMethod.threadFork,
                          !answered.contains(id) else { continue }
                    answered.insert(id)
                    await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"thread":{"id":"\#(newId)","forkedFromId":"\#(from)","ephemeral":true}}}"#)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
    @Test func defaultForkOmitsEphemeral() async {
        let (mock, store) = await makeStore()
        let r = respondFork(mock, newId: "fork-1", from: "t1")
        _ = await store.fork()
        r.cancel()
        let forkFrame = await mock.sent.first { $0.contains(RPCMethod.threadFork) } ?? ""
        #expect(!forkFrame.contains("ephemeral"))
    }
    @Test func ephemeralForkReturnsIdAndParent() async {
        let (mock, store) = await makeStore()
        let r = respondFork(mock, newId: "fork-1", from: "t1")
        let result = await store.fork(ephemeral: true)
        r.cancel()
        let forkFrame = await mock.sent.first { $0.contains(RPCMethod.threadFork) } ?? ""
        #expect(forkFrame.contains("\"ephemeral\":true"))
        #expect(result?.threadId == "fork-1")
        #expect(result?.forkedFromId == "t1")
    }
}
