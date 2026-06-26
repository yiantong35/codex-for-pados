import Foundation
import Crypto

/// SSH 字节通道上的 ws 客户端握手 + 帧编解码（RFC6455 子集：text frame / 掩码 / 分片重组）。
/// 不复用 URLSessionWebSocketTask（其无法跑在 SSH exec 通道字节流上）。
enum WSFrame {
    /// 生成客户端握手请求文本 + 本次随机 Sec-WebSocket-Key（base64）。
    static func handshakeRequest(host: String = "localhost", path: String = "/") -> (request: String, key: String) {
        var keyBytes = Data(count: 16)
        keyBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = keyBytes.base64EncodedString()
        let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                  "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        return (req, key)
    }

    /// 期望的 Sec-WebSocket-Accept = base64(SHA1(key + GUID))。
    static func expectedAccept(forKey key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// 校验响应头：含 `101` 且 Sec-WebSocket-Accept == expectedAccept(forKey:)。
    static func validateHandshake(responseHead: String, key: String) -> Bool {
        guard responseHead.contains("101") else { return false }
        let want = expectedAccept(forKey: key)
        return responseHead.range(of: "Sec-WebSocket-Accept:", options: .caseInsensitive) != nil
            && responseHead.contains(want)
    }

    /// 编码一条客户端 text frame：FIN=1, opcode=0x1, MASK=1（客户端必须掩码），含 4 字节随机掩码键。
    static func encodeTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data()
        frame.append(0x81)                                  // FIN=1, opcode=0x1(text)
        let len = payload.count
        let maskBit: UInt8 = 0x80                           // 客户端 MASK=1
        if len <= 125 {
            frame.append(maskBit | UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((len >> 8) & 0xFF)); frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((len >> shift) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        for (i, b) in payload.enumerated() { frame.append(b ^ mask[i % 4]) }
        return frame
    }

    /// 增量解码：把累积缓冲切出 0..n 条完整 text 帧（重组分片，跳过 ping/pong/close 控制帧的 payload）。
    /// 返回解出的文本数组；剩余未消费字节保留在 buffer 中。服务端→客户端帧不掩码。
    static func decodeFrames(buffer: inout Data) -> [String] {
        var out: [String] = []
        var assembling = Data()          // 跨分片累积的 text payload
        var inText = false
        while true {
            guard buffer.count >= 2 else { break }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0   // 服务端帧应为 0
            var len = Int(b1 & 0x7F)
            var idx = buffer.startIndex + 2
            if len == 126 {
                guard buffer.count >= 4 else { break }
                len = Int(buffer[idx]) << 8 | Int(buffer[idx+1]); idx += 2
            } else if len == 127 {
                guard buffer.count >= 10 else { break }
                len = 0; for k in 0..<8 { len = (len << 8) | Int(buffer[idx+k]) }; idx += 8
            }
            let maskLen = masked ? 4 : 0
            guard buffer.count >= (idx - buffer.startIndex) + maskLen + len else { break }
            var maskKey = [UInt8](repeating: 0, count: 4)
            if masked { for k in 0..<4 { maskKey[k] = buffer[idx+k] }; idx += 4 }
            var payload = Data(buffer[idx..<idx+len])
            if masked { for i in 0..<payload.count { payload[payload.startIndex+i] ^= maskKey[i % 4] } }
            buffer.removeSubrange(buffer.startIndex..<(idx+len))
            switch opcode {
            case 0x1:                       // text 起始帧
                inText = true; assembling = payload
                if fin { out.append(String(decoding: assembling, as: UTF8.self)); inText = false; assembling = Data() }
            case 0x0 where inText:          // 续帧
                assembling.append(payload)
                if fin { out.append(String(decoding: assembling, as: UTF8.self)); inText = false; assembling = Data() }
            default: break                  // ping/pong/close/binary：本子集忽略 payload
            }
        }
        return out
    }
}
