import Foundation
import RelayProtocol

/// 一台机器的连接配置（多机器 tab 容器的持久化单元）。
/// relay-only：连接方式仅 relay 中继，字段直接内联在 `MachineConfig` 顶层
/// （relayURL/sessionId/devIdentityPubB64 均为非敏感结构化字段）；
/// 配对码（pc）绝不持久化，只驻内存 PendingPairingStore。
/// Codable 写入字段：id / displayName / relayURL / sessionId / devIdentityPubB64 / lastActiveAt；
/// 解码兼容上一版嵌套 `connection` 的 relay 数据，并丢弃旧 pairing 串中的配对码。
struct MachineConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var relayURL: String
    var sessionId: String
    var devIdentityPubB64: String
    var lastActiveAt: Date?

    /// 主构造器。displayName 为空则回落空串（relay 无天然 host 概念，调用方保证传入非空更友好的名字）。
    init(id: UUID = UUID(), displayName: String? = nil,
         relayURL: String, sessionId: String, devIdentityPubB64: String,
         lastActiveAt: Date? = nil) {
        self.id = id
        self.relayURL = relayURL
        self.sessionId = sessionId
        self.devIdentityPubB64 = devIdentityPubB64
        self.displayName = (displayName?.isEmpty == false) ? displayName! : ""
        self.lastActiveAt = lastActiveAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, relayURL, sessionId, devIdentityPubB64, lastActiveAt, connection
    }

    private enum LegacyConnectionKeys: String, CodingKey {
        case kind, relayURL, sessionId, devIdentityPubB64, pairing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)

        if let relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL),
           let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId),
           let devIdentityPubB64 = try container.decodeIfPresent(String.self, forKey: .devIdentityPubB64) {
            self.relayURL = relayURL
            self.sessionId = sessionId
            self.devIdentityPubB64 = devIdentityPubB64
            return
        }

        let legacy = try container.nestedContainer(keyedBy: LegacyConnectionKeys.self,
                                                   forKey: .connection)
        guard try legacy.decode(String.self, forKey: .kind) == "relay" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: legacy,
                debugDescription: "Only legacy relay machine configurations are supported"
            )
        }

        if let relayURL = try legacy.decodeIfPresent(String.self, forKey: .relayURL) {
            self.relayURL = relayURL
            sessionId = try legacy.decode(String.self, forKey: .sessionId)
            devIdentityPubB64 = try legacy.decode(String.self, forKey: .devIdentityPubB64)
        } else {
            let pairing = try legacy.decode(String.self, forKey: .pairing)
            let payload = try PairingPayload(parsing: pairing)
            relayURL = payload.relayURL
            sessionId = payload.sessionId
            devIdentityPubB64 = payload.devIdentityPubB64
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(relayURL, forKey: .relayURL)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(devIdentityPubB64, forKey: .devIdentityPubB64)
        try container.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
    }

    /// 转为连接层 ConnectionConfig；transportFactory 据此 + 内存 pc 构造 RelayTransport。
    var connectionConfig: ConnectionConfig {
        ConnectionConfig(relayURL: relayURL, relaySessionId: sessionId,
                        relayDevIdentityPubB64: devIdentityPubB64, relayTOFUKey: id.uuidString)
    }
}
