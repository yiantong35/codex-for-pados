import Foundation
import RelayProtocol

/// 一台机器的连接配置（多机器 tab 容器的持久化单元）。
/// relay-only：连接方式仅 relay 中继，字段直接内联在 `MachineConfig` 顶层
/// （relayURL/sessionId/devIdentityPubB64 均为非敏感结构化字段）；
/// 配对码（pc）绝不持久化，只驻内存 PendingPairingStore。
enum ConnectionIntent: String, Codable, Equatable {
    case automatic
    case disconnectedByUser
}

struct MachineConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var relayURL: String
    var sessionId: String
    var devIdentityPubB64: String
    var lastActiveAt: Date?
    var connectionIntent: ConnectionIntent

    /// 主构造器。displayName 为空则回落空串（relay 无天然 host 概念，调用方保证传入非空更友好的名字）。
    init(id: UUID = UUID(), displayName: String? = nil,
         relayURL: String, sessionId: String, devIdentityPubB64: String,
         lastActiveAt: Date? = nil, connectionIntent: ConnectionIntent = .automatic) {
        self.id = id
        self.relayURL = relayURL
        self.sessionId = sessionId
        self.devIdentityPubB64 = devIdentityPubB64
        self.displayName = (displayName?.isEmpty == false) ? displayName! : ""
        self.lastActiveAt = lastActiveAt
        self.connectionIntent = connectionIntent
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, relayURL, sessionId, devIdentityPubB64, lastActiveAt, connectionIntent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        relayURL = try container.decode(String.self, forKey: .relayURL)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        devIdentityPubB64 = try container.decode(String.self, forKey: .devIdentityPubB64)
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        connectionIntent = try container.decodeIfPresent(ConnectionIntent.self, forKey: .connectionIntent) ?? .automatic
    }

    /// 转为连接层 ConnectionConfig；transportFactory 据此 + 内存 pc 构造 RelayTransport。
    var connectionConfig: ConnectionConfig {
        ConnectionConfig(relayURL: relayURL, relaySessionId: sessionId,
                        relayDevIdentityPubB64: devIdentityPubB64, relayTOFUKey: id.uuidString)
    }
}
