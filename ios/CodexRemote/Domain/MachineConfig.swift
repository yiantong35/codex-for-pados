import Foundation
import RelayProtocol

/// 一台机器的连接配置（多机器 tab 容器的持久化单元）。
/// relay-only：连接方式仅 relay 中继，字段直接内联在 `MachineConfig` 顶层
/// （relayURL/sessionId/devIdentityPubB64 均为非敏感结构化字段）；
/// 配对码（pc）绝不持久化，只驻内存 PendingPairingStore。
/// Codable 使用合成实现，字段：id / displayName / relayURL / sessionId / devIdentityPubB64 / lastActiveAt。
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

    /// 转为连接层 ConnectionConfig；transportFactory 据此 + 内存 pc 构造 RelayTransport。
    var connectionConfig: ConnectionConfig {
        ConnectionConfig(relayURL: relayURL, relaySessionId: sessionId,
                        relayDevIdentityPubB64: devIdentityPubB64, relayTOFUKey: id.uuidString)
    }
}
