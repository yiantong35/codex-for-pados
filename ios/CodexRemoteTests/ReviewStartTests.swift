import Testing
import Foundation
@testable import CodexRemote

struct ReviewStartTests {
    @MainActor @Test func submissionGateRejectsRapidDuplicates() {
        #expect(ReviewTabView.canSubmitReview(sourceAvailable: true, isSubmitting: false))
        #expect(!ReviewTabView.canSubmitReview(sourceAvailable: true, isSubmitting: true))
        #expect(!ReviewTabView.canSubmitReview(sourceAvailable: false, isSubmitting: false))
    }

    @Test func reviewStartMethodConstant() {
        #expect(RPCMethod.reviewStart == "review/start")
    }

    // 编码：uncommittedChanges 目标 + inline 投递
    @Test func encodeUncommittedInlineParams() throws {
        let params = ReviewStartParams(
            threadId: "t1",
            target: .uncommittedChanges,
            delivery: .inline
        )
        let obj = try Self.encodeToObject(params)
        #expect(obj["threadId"] as? String == "t1")
        #expect(obj["delivery"] as? String == "inline")
        let target = obj["target"] as? [String: Any]
        #expect(target?["type"] as? String == "uncommittedChanges")
        // uncommittedChanges 不应带 instructions 字段
        #expect(target?["instructions"] == nil)
    }

    // 编码：custom{instructions} 目标
    @Test func encodeCustomParams() throws {
        let params = ReviewStartParams(
            threadId: "t2",
            target: .custom(instructions: "请审查以下改动：\n<diff>"),
            delivery: .inline
        )
        let obj = try Self.encodeToObject(params)
        #expect(obj["threadId"] as? String == "t2")
        let target = obj["target"] as? [String: Any]
        #expect(target?["type"] as? String == "custom")
        #expect((target?["instructions"] as? String)?.contains("<diff>") == true)
    }

    // 响应：宽松解码，只取 reviewThreadId，turn 复杂结构忽略不崩
    @Test func decodeResponseLenient() throws {
        let json = #"{"reviewThreadId":"t1","turn":{"id":"turn_1","items":[],"status":"inProgress"}}"#
        let resp = try JSONDecoder().decode(ReviewStartResponse.self, from: Data(json.utf8))
        #expect(resp.reviewThreadId == "t1")
    }

    // .full → 发出 review/start，target=uncommittedChanges、delivery=inline、threadId 正确
    @MainActor @Test func startReviewFullSendsUncommitted() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "thread-A")
        let sent = await store.startReview(mode: .full)
        #expect(sent == true)
        let frame = await mock.sent.first { $0.contains("review/start") }
        #expect(frame != nil)
        #expect(frame?.contains("thread-A") == true)
        #expect(frame?.contains("uncommittedChanges") == true)
        #expect(frame?.contains("inline") == true)
    }

    // 服务端拒绝 → 返回 false，供 ReviewTabView 展示失败而不是“已开始”。
    @MainActor @Test func startReviewServerErrorReturnsFalse() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "thread-error")
        let responder = Task {
            for _ in 0..<200 {
                if let frame = await mock.sent.first(where: { $0.contains("review/start") }),
                   let data = frame.data(using: .utf8),
                   case .request(let request)? = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) {
                    let id: String
                    switch request.id {
                    case .string(let value): id = "\"\(value)\""
                    case .int(let value): id = "\(value)"
                    }
                    await mock.feed(#"{"id":\#(id),"error":{"code":-32602,"message":"rejected"}}"#)
                    return
                }
                await Task.yield()
            }
        }

        let accepted = await store.startReview(mode: .full)
        await responder.value
        #expect(!accepted)
    }

    // 无 threadId → 不发请求，返回 false
    @MainActor @Test func startReviewNoThreadDoesNotSend() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "")
        let sent = await store.startReview(mode: .full)
        #expect(sent == false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("review/start") } == false)
    }

    // .turn 且 turnDiff 为空 → 不发请求，返回 false
    @MainActor @Test func startReviewTurnEmptyDiffDoesNotSend() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "thread-B")
        // 新建 store 的 state.turnDiff 默认 ""（见 ConversationModels.swift:68）
        let sent = await store.startReview(mode: .turn)
        #expect(sent == false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("review/start") } == false)
    }

    // 测试辅助：Encodable → [String: Any]（校验线格式字段名/判别字段）
    static func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
