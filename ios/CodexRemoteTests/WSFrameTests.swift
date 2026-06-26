import XCTest
@testable import CodexRemote

final class WSFrameTests: XCTestCase {
    func testHandshakeRequestShape() {
        let (req, key) = WSFrame.handshakeRequest()
        XCTAssertTrue(req.contains("Upgrade: websocket"))
        XCTAssertTrue(req.contains("Sec-WebSocket-Version: 13"))
        XCTAssertTrue(req.contains("Sec-WebSocket-Key: \(key)"))
        XCTAssertEqual(Data(base64Encoded: key)?.count, 16)
    }

    func testExpectedAcceptMatchesRFCExample() {
        // RFC6455 §1.3 经典示例：key=dGhlIHNhbXBsZSBub25jZQ== → accept=s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
        XCTAssertEqual(WSFrame.expectedAccept(forKey: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testValidateHandshakeOnlyWith101AndCorrectAccept() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        XCTAssertTrue(WSFrame.validateHandshake(responseHead: good, key: key))
        let bad = "HTTP/1.1 200 OK\r\n\r\n"
        XCTAssertFalse(WSFrame.validateHandshake(responseHead: bad, key: key))
    }

    func testEncodeTextFrameIsMaskedClientFrame() {
        let data = WSFrame.encodeTextFrame("hi")
        XCTAssertEqual(data[data.startIndex], 0x81)            // FIN+text
        XCTAssertEqual(data[data.startIndex+1] & 0x80, 0x80)  // MASK=1
        XCTAssertEqual(Int(data[data.startIndex+1] & 0x7F), 2) // len=2
        XCTAssertEqual(data.count, 2 + 4 + 2)                  // hdr+mask+payload
    }

    func testRoundTripViaServerFrame() {
        // 构造一个服务端→客户端（不掩码）text 帧，断言 decodeFrames 还原文本。
        let payload = Array("{\"jsonrpc\":\"2.0\"}".utf8)
        var server = Data([0x81, UInt8(payload.count)]); server.append(contentsOf: payload)
        var buf = server
        XCTAssertEqual(WSFrame.decodeFrames(buffer: &buf), ["{\"jsonrpc\":\"2.0\"}"])
        XCTAssertTrue(buf.isEmpty)
    }

    func testDecodeFragmentedTextFrames() {
        // 分片：opcode=text FIN=0 "ab" + opcode=cont FIN=1 "cd" → "abcd"
        var buf = Data([0x01, 0x02, 0x61, 0x62,   // text, FIN=0, "ab"
                        0x80, 0x02, 0x63, 0x64])   // cont, FIN=1, "cd"
        XCTAssertEqual(WSFrame.decodeFrames(buffer: &buf), ["abcd"])
    }

    func testDecodeHoldsIncompleteFrame() {
        var buf = Data([0x81, 0x05, 0x68])  // 声称 len=5 只给 1 字节 → 不应吐帧
        XCTAssertEqual(WSFrame.decodeFrames(buffer: &buf), [])
        XCTAssertEqual(buf.count, 3)        // 原样保留待续
    }
}
