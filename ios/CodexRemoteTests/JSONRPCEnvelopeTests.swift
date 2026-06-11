import XCTest
@testable import CodexRemote

final class JSONRPCEnvelopeTests: XCTestCase {
    func testDecodeResponseWithIntId() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .response(let r) = msg else { return XCTFail("应为 response") }
        XCTAssertEqual(r.id, .int(1))
    }
    func testDecodeNotificationNoId() throws {
        let json = #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"x":1}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .notification(let n) = msg else { return XCTFail("应为 notification") }
        XCTAssertEqual(n.method, "item/agentMessage/delta")
    }
    func testDecodeServerRequestStringId() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"item/commandExecution/requestApproval","params":{}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .request(let r) = msg else { return XCTFail("应为 request") }
        XCTAssertEqual(r.id, .string("abc"))
        XCTAssertEqual(r.method, "item/commandExecution/requestApproval")
    }
    func testDecodeError() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method not found"}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .error(let e) = msg else { return XCTFail("应为 error") }
        XCTAssertEqual(e.error.code, -32601)
    }
    func testEncodeRequestRoundTrip() throws {
        let req = JSONRPCRequest(id: .int(7), method: "thread/list",
                                 params: AnyCodable(["limit": 20]))
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(back.id, .int(7))
        XCTAssertEqual(back.method, "thread/list")
    }
}
