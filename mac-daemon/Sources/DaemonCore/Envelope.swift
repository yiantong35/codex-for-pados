import Foundation

/// Envelope 解码错误。
public enum EnvelopeError: Error, Equatable {
    case unknownType(String)
    case invalidPayload
}

/// daemon ↔ 下游 的 WS 文本帧协议(见设计 D4)。
/// 一条文本帧 = 一条 envelope JSON(单行)。
///
/// 四类帧:
/// - `event`(daemon→下游广播):`{type:"event", seq, payload}`,payload 为 app-server 原始 JSON-RPC(不透明)。
/// - `request`(下游→daemon→app-server):`{type:"request", payload}`,payload 为 JSON-RPC request(不透明)。
/// - `resync`(下游→daemon):`{type:"resync", after}`。
/// - `snapshotNeeded`(daemon→下游):`{type:"snapshot-needed"}`。
public enum Envelope: Equatable, Sendable {
    case event(seq: UInt64, payload: JSONValue)
    case request(payload: JSONValue)
    case resync(after: UInt64)
    case snapshotNeeded
}

extension Envelope {
    /// 从 SeqBuffer 分配的 `Event` 构造 event 帧。
    /// `Event.payload` 是原始 JSON 的 Data,解析为不透明 JSONValue 透传。
    public static func event(from event: Event) throws -> Envelope {
        let payload = try JSONValue(parsing: event.payload)
        return .event(seq: event.seq, payload: payload)
    }
}

// MARK: - Codable(线格式)

extension Envelope: Codable {
    private enum WireType: String, Codable {
        case event
        case request
        case resync
        case snapshotNeeded = "snapshot-needed"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case seq
        case payload
        case after
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try c.decode(String.self, forKey: .type)
        guard let type = WireType(rawValue: typeString) else {
            throw EnvelopeError.unknownType(typeString)
        }
        switch type {
        case .event:
            let seq = try c.decode(UInt64.self, forKey: .seq)
            let payload = try c.decode(JSONValue.self, forKey: .payload)
            self = .event(seq: seq, payload: payload)
        case .request:
            let payload = try c.decode(JSONValue.self, forKey: .payload)
            self = .request(payload: payload)
        case .resync:
            let after = try c.decode(UInt64.self, forKey: .after)
            self = .resync(after: after)
        case .snapshotNeeded:
            self = .snapshotNeeded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .event(seq, payload):
            try c.encode(WireType.event, forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(payload, forKey: .payload)
        case let .request(payload):
            try c.encode(WireType.request, forKey: .type)
            try c.encode(payload, forKey: .payload)
        case let .resync(after):
            try c.encode(WireType.resync, forKey: .type)
            try c.encode(after, forKey: .after)
        case .snapshotNeeded:
            try c.encode(WireType.snapshotNeeded, forKey: .type)
        }
    }

    // MARK: - 一帧 = 一行 JSON

    /// 编码为单行 JSON 文本帧字节。
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        // 默认无 .prettyPrinted → 单行,符合 WS 文本帧约定。
        return try encoder.encode(self)
    }

    /// 从单条文本帧字节解码。非法帧抛错。
    public static func decode(from data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }
}
