import Testing
import Foundation
@testable import CodexRemote

struct ReviewStartTests {
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

    // 测试辅助：Encodable → [String: Any]（校验线格式字段名/判别字段）
    static func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
