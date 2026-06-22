import XCTest
import Foundation
@testable import DaemonCore

final class EnvelopeTests: XCTestCase {

    // MARK: - 辅助:把 JSON 文本解析成 JSONValue / 把 envelope round-trip

    private func decode(_ json: String) throws -> Envelope {
        try Envelope.decode(from: Data(json.utf8))
    }

    private func encodeToString(_ env: Envelope) throws -> String {
        let data = try env.encode()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - event 帧 round-trip

    func testEventRoundTrip() throws {
        let payload = try JSONValue(parsing: #"{"method":"turn/started","params":{"id":1}}"#)
        let env = Envelope.event(seq: 42, payload: payload)

        let data = try env.encode()
        let decoded = try Envelope.decode(from: data)

        XCTAssertEqual(decoded, env)
        guard case let .event(seq, p) = decoded else {
            return XCTFail("expected .event, got \(decoded)")
        }
        XCTAssertEqual(seq, 42)
        XCTAssertEqual(p, payload)
    }

    // MARK: - request 帧 round-trip

    func testRequestRoundTrip() throws {
        let payload = try JSONValue(parsing: #"{"jsonrpc":"2.0","id":7,"method":"turn/start","params":{}}"#)
        let env = Envelope.request(payload: payload)

        let decoded = try Envelope.decode(from: env.encode())
        XCTAssertEqual(decoded, env)
        guard case let .request(p) = decoded else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(p, payload)
    }

    // MARK: - resync 帧 round-trip

    func testResyncRoundTrip() throws {
        let env = Envelope.resync(after: 1234)
        let decoded = try Envelope.decode(from: env.encode())
        XCTAssertEqual(decoded, env)
        guard case let .resync(after) = decoded else {
            return XCTFail("expected .resync")
        }
        XCTAssertEqual(after, 1234)
    }

    // MARK: - snapshotNeeded 帧 round-trip

    func testSnapshotNeededRoundTrip() throws {
        let env = Envelope.snapshotNeeded
        let decoded = try Envelope.decode(from: env.encode())
        XCTAssertEqual(decoded, env)
        guard case .snapshotNeeded = decoded else {
            return XCTFail("expected .snapshotNeeded")
        }
    }

    // MARK: - snapshotNeeded 线格式使用 kebab-case type

    func testSnapshotNeededWireType() throws {
        let s = try encodeToString(.snapshotNeeded)
        XCTAssertTrue(s.contains("\"snapshot-needed\""), "wire type should be snapshot-needed, got: \(s)")
    }

    // MARK: - payload 原样保真:嵌套 JSON

    func testPayloadFidelityNestedJSON() throws {
        let raw = #"{"a":{"b":{"c":[1,2,3,{"d":true,"e":null}]}},"f":3.5}"#
        let payload = try JSONValue(parsing: raw)
        let env = Envelope.event(seq: 1, payload: payload)

        let decoded = try Envelope.decode(from: env.encode())
        guard case let .event(_, p) = decoded else { return XCTFail() }
        XCTAssertEqual(p, payload)
    }

    // MARK: - payload 原样保真:中文 / 特殊字符

    func testPayloadFidelityUnicodeAndSpecials() throws {
        let raw = #"{"msg":"你好,世界 \"引号\" \\反斜杠 \n换行\t制表 😀 emoji","k":"a/b"}"#
        let payload = try JSONValue(parsing: raw)
        let env = Envelope.event(seq: 2, payload: payload)

        let decoded = try Envelope.decode(from: env.encode())
        guard case let .event(_, p) = decoded else { return XCTFail() }
        XCTAssertEqual(p, payload)

        // 取出字符串值,确认中文/emoji 字面保真
        guard case let .object(obj) = p, case let .string(msg)? = obj["msg"] else {
            return XCTFail("expected msg string")
        }
        XCTAssertTrue(msg.contains("你好"))
        XCTAssertTrue(msg.contains("😀"))
    }

    // MARK: - payload 原样保真:大对象

    func testPayloadFidelityLargeObject() throws {
        var fields: [String] = []
        for i in 0..<500 {
            fields.append("\"k\(i)\":\"v\(i)值\(i)\"")
        }
        let raw = "{" + fields.joined(separator: ",") + "}"
        let payload = try JSONValue(parsing: raw)
        let env = Envelope.event(seq: 999, payload: payload)

        let decoded = try Envelope.decode(from: env.encode())
        guard case let .event(_, p) = decoded else { return XCTFail() }
        XCTAssertEqual(p, payload)
    }

    // MARK: - payload 数字精度(整型 / UInt64 大值)

    func testPayloadIntegerFidelity() throws {
        let raw = #"{"big":9007199254740993,"zero":0,"neg":-42}"#
        let payload = try JSONValue(parsing: raw)
        let env = Envelope.request(payload: payload)

        let decoded = try Envelope.decode(from: env.encode())
        guard case let .request(p) = decoded else { return XCTFail() }
        XCTAssertEqual(p, payload)
    }

    // MARK: - 一条帧 = 单行(无内嵌换行)

    func testEncodedFrameIsSingleLine() throws {
        let payload = try JSONValue(parsing: #"{"x":[1,2,3],"y":{"z":"v"}}"#)
        let env = Envelope.event(seq: 5, payload: payload)
        let s = try encodeToString(env)
        XCTAssertFalse(s.contains("\n"), "encoded envelope must be single line, got: \(s)")
    }

    // MARK: - 非法帧解码报错

    func testDecodeRejectsUnknownType() {
        XCTAssertThrowsError(try decode(#"{"type":"bogus","seq":1}"#))
    }

    func testDecodeRejectsMalformedJSON() {
        XCTAssertThrowsError(try decode(#"{not json"#))
    }

    func testDecodeRejectsMissingType() {
        XCTAssertThrowsError(try decode(#"{"seq":1,"payload":{}}"#))
    }

    func testDecodeRejectsEventMissingSeq() {
        XCTAssertThrowsError(try decode(#"{"type":"event","payload":{}}"#))
    }

    func testDecodeRejectsResyncMissingAfter() {
        XCTAssertThrowsError(try decode(#"{"type":"resync"}"#))
    }

    func testDecodeRejectsEmpty() {
        XCTAssertThrowsError(try decode(""))
    }

    // MARK: - 与 SeqBuffer.Event 衔接:event 帧能从 Event 构造

    func testEnvelopeFromSeqBufferEvent() throws {
        // SeqBuffer 分配的 Event.payload 是原始 JSON 的 Data。
        let rawPayload = #"{"method":"item/started","params":{"item":"abc"}}"#
        var buffer = SeqBuffer(capacity: 10)
        let (seq, event) = buffer.append(Data(rawPayload.utf8))

        // 能从 Event 直接构造 event envelope。
        let env = try Envelope.event(from: event)

        guard case let .event(envSeq, payload) = env else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(envSeq, seq)
        XCTAssertEqual(payload, try JSONValue(parsing: rawPayload))

        // round-trip 后仍等价。
        let decoded = try Envelope.decode(from: env.encode())
        XCTAssertEqual(decoded, env)
    }

    // MARK: - event payload 可还原为原始 Data(交回 SeqBuffer/transparent 透传)

    func testEventPayloadBackToData() throws {
        let rawPayload = #"{"k":"v","n":1}"#
        let payload = try JSONValue(parsing: rawPayload)
        let env = Envelope.event(seq: 3, payload: payload)
        guard case let .event(_, p) = env else { return XCTFail() }

        // 再编码出的 Data 解析回 JSONValue 应等价(语义保真,不强求字节级一致)。
        let asData = try p.encode()
        XCTAssertEqual(try JSONValue(parsing: String(decoding: asData, as: UTF8.self)), payload)
    }
}
