import Foundation
import RelayProtocol

/// 分片载荷（位于 .chunk 帧的密封明文内）。字段/类型/顺序与 iOS 侧 ChunkPayload 完全一致。
internal struct ChunkPayload: Codable, Equatable {
    var seq: UInt32
    var totalChunks: UInt32
    var compressed: Bool
    var data: Data
}

/// 每片明文预算：512 KiB。密封后 JSON(base64) + 信封开销后整帧必 ≪ 1 MiB（设计 §2.2 留足余量）。
internal let chunkPlaintextBudget = 512 * 1024

/// 开发机发送侧的最终 wire-limit 守卫。超限 response 改写成同 id 的小型 JSON-RPC error，
/// server request 则把 error 退回 app-server；无 id 的超限通知本地拒绝。
public enum DialoutOutboundFrameBuildResult: Equatable {
    case frame(Data)
    case frames([Data])      // 分片帧：每片为一个完整 SecureEnvelope（kind=.chunk）
    case rejectUpstream(String)
    case dropped
}

public enum DialoutOutboundFrameBuilder {
    public static func build(line: String, session: SecureSession,
                             maxBytes: Int = RelayWireLimits.maxMessageBytes,
                             peerSupportsChunk: Bool = false) throws
        -> DialoutOutboundFrameBuildResult {
        let original = try encode(line: line, session: session)
        guard original.count > maxBytes else { return .frame(original) }
        // 协商成功：超限分支整体替换为分片（含 notification/request——分片后整行完整送达，不再区分）。
        // 未协商：维持既有 -32010 / rejectUpstream / dropped 语义（旧端不被打崩）。
        if peerSupportsChunk {
            return try chunkedFrames(line: line, session: session, maxBytes: maxBytes)
        }
        guard let classification = classifyOversized(line) else { return .dropped }
        let rejection = classification.rejection
        if classification.isServerRequest { return .rejectUpstream(rejection) }
        let compact = try encode(line: rejection, session: session)
        return compact.count <= maxBytes ? .frame(compact) : .dropped
    }

    /// 把整行明文按字节切成 N 片（每片 ≤ chunkPlaintextBudget），产生 seq 从 0 起的 ChunkPayload 列表。
    internal static func chunkPayloads(plaintext: Data, compressed: Bool) -> [ChunkPayload] {
        guard !plaintext.isEmpty else {
            return [ChunkPayload(seq: 0, totalChunks: 1, compressed: compressed, data: plaintext)]
        }
        let count = max(1, (plaintext.count + chunkPlaintextBudget - 1) / chunkPlaintextBudget)
        let total = UInt32(count)
        var result: [ChunkPayload] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let start = i * chunkPlaintextBudget
            let end = min(start + chunkPlaintextBudget, plaintext.count)
            result.append(ChunkPayload(seq: UInt32(i), totalChunks: total,
                                       compressed: compressed, data: Data(plaintext[start..<end])))
        }
        return result
    }

    /// 逐片 seal(kind=.chunk) 编码；任一帧超 maxBytes 防御性 fail-closed（预算内理论不触发）。
    private static func chunkedFrames(line: String, session: SecureSession, maxBytes: Int) throws
        -> DialoutOutboundFrameBuildResult {
        let plaintext = Data(line.utf8)
        let compressed = false   // Task 4 引入压缩决策；此 task 恒不压缩
        let payloads = chunkPayloads(plaintext: plaintext, compressed: compressed)
        var frames: [Data] = []
        frames.reserveCapacity(payloads.count)
        for payload in payloads {
            let payloadData = try JSONEncoder().encode(payload)
            let env = try session.seal(payloadData, kind: .chunk)
            let encoded = try env.encoded()
            guard encoded.count <= maxBytes else { return .dropped }  // 防御性 fail-closed
            frames.append(encoded)
        }
        return .frames(frames)
    }

    private static func encode(line: String, session: SecureSession) throws -> Data {
        let envelope = try session.seal(Data(line.utf8), kind: .appData)
        return try envelope.encoded()
    }

    private static func classifyOversized(_ line: String)
        -> (rejection: String, isServerRequest: Bool)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"], !(id is NSNull) else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32010,
                "message": RelayWireLimits.outboundResponseTooLargeMessage,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let encoded = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: encoded, encoding: .utf8) else { return nil }
        return (text, object["method"] is String)
    }
}
