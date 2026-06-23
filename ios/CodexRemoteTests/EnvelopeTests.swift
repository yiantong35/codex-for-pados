import XCTest
@testable import CodexRemote

final class EnvelopeTests: XCTestCase {
    // 出向：把一行 JSON-RPC 文本包成 {type:"request",payload:<对象>}
    func testEncodeRequestEnvelope() throws {
        let rpcLine = #"{"id":"ipad-1","method":"thread/list","params":{"limit":1}}"#
        let line = try EnvelopeCodec.encodeRequest(payloadJSON: rpcLine)
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "request")
        let payload = obj["payload"] as! [String: Any]
        XCTAssertEqual(payload["id"] as? String, "ipad-1")
        XCTAssertEqual(payload["method"] as? String, "thread/list")
        XCTAssertFalse(line.contains("\n"))   // 一帧一行
    }

    // 入向 event：解出 seq 与 payload（payload 重新序列化为一行 JSON）
    func testDecodeEventEnvelope() throws {
        let frame = #"{"type":"event","seq":7,"payload":{"jsonrpc":"2.0","id":"ipad-1","result":{"ok":true}}}"#
        guard case .event(let seq, let payloadJSON) = try EnvelopeCodec.decode(line: frame) else {
            return XCTFail("应解为 event")
        }
        XCTAssertEqual(seq, 7)
        let obj = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "ipad-1")
        XCTAssertFalse(payloadJSON.contains("\n"))
    }

    // 入向 snapshot-needed
    func testDecodeSnapshotNeeded() throws {
        let frame = #"{"type":"snapshot-needed"}"#
        guard case .snapshotNeeded = try EnvelopeCodec.decode(line: frame) else {
            return XCTFail("应解为 snapshotNeeded")
        }
    }

    // 未知 type → 抛 unknownType（而非崩溃/静默）
    func testDecodeUnknownTypeThrows() {
        XCTAssertThrowsError(try EnvelopeCodec.decode(line: #"{"type":"weird"}"#))
    }
}
