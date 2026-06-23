import Foundation

/// daemon 入向 envelope（解码后供 WSTransport 消费）。出向只需 request，故单独编码。
enum IncomingEnvelope {
    case event(seq: UInt64, payloadJSON: String)
    case resync(after: UInt64)        // iPad 一般不收 resync，但完整覆盖协议
    case snapshotNeeded
}

enum EnvelopeError: Error, Equatable {
    case malformed
    case unknownType(String)
}

/// envelope 一帧 = 一行 JSON。出向包 request，入向解 event/snapshot-needed。
/// payload 透传：用 JSONSerialization 把任意 JSON 对象重新序列化成紧凑单行，
/// 与旧 stdio「一行 JSON」帧形状一致，复用现有 RPC 解码路径（设计 §4 A1）。
enum EnvelopeCodec {
    /// 把一行 JSON-RPC 文本包成 {"type":"request","payload":<对象>} 的一行 JSON。
    static func encodeRequest(payloadJSON: String) throws -> String {
        guard let payloadObj = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) else {
            throw EnvelopeError.malformed
        }
        let envelope: [String: Any] = ["type": "request", "payload": payloadObj]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// 解一行入向 envelope。
    static func decode(line: String) throws -> IncomingEnvelope {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String else {
            throw EnvelopeError.malformed
        }
        switch type {
        case "event":
            guard let seq = (obj["seq"] as? NSNumber)?.uint64Value,
                  let payload = obj["payload"] else { throw EnvelopeError.malformed }
            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
            return .event(seq: seq, payloadJSON: String(decoding: payloadData, as: UTF8.self))
        case "resync":
            guard let after = (obj["after"] as? NSNumber)?.uint64Value else { throw EnvelopeError.malformed }
            return .resync(after: after)
        case "snapshot-needed":
            return .snapshotNeeded
        default:
            throw EnvelopeError.unknownType(type)
        }
    }
}
