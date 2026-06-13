import Foundation

enum RequestId: Codable, Hashable {
    case string(String), int(Int64)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int64.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .int(let i): try c.encode(i) }
    }
}

// 注意：`jsonrpc` 用可选类型。真实 codex app-server 的响应/通知**不带** `"jsonrpc"` 字段，
// 而 Swift 合成的 Decodable 对非可选属性缺键即抛错（默认值不会被解码用到）。可选 → 缺失容错，
// 发送时默认仍为 "2.0" 被编码进去。
struct JSONRPCRequest: Codable, Sendable {
    var jsonrpc: String? = "2.0"
    let id: RequestId
    let method: String
    var params: AnyCodable?
}

struct JSONRPCNotification: Codable, Sendable {
    var jsonrpc: String? = "2.0"
    let method: String
    var params: AnyCodable?
}

struct JSONRPCResponse: Codable, Sendable {
    var jsonrpc: String? = "2.0"
    let id: RequestId
    let result: AnyCodable
}

struct JSONRPCErrorBody: Codable, Sendable { let code: Int; let message: String; var data: AnyCodable? }
struct JSONRPCError: Codable, Sendable {
    var jsonrpc: String? = "2.0"
    let id: RequestId
    let error: JSONRPCErrorBody
}

enum JSONRPCMessage: Decodable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case error(JSONRPCError)

    private enum Keys: String, CodingKey { case id, method, result, error }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        let hasId = c.contains(.id)
        if c.contains(.error) { self = .error(try JSONRPCError(from: d)) }
        else if c.contains(.method) {
            if hasId { self = .request(try JSONRPCRequest(from: d)) }
            else { self = .notification(try JSONRPCNotification(from: d)) }
        } else if c.contains(.result) {
            self = .response(try JSONRPCResponse(from: d))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                debugDescription: "无法识别的 JSON-RPC 消息"))
        }
    }
}
