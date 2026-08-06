import Foundation
import RelayProtocol

/// 开发机发送侧的最终 wire-limit 守卫。超限 response 改写成同 id 的小型 JSON-RPC error，
/// server request 则把 error 退回 app-server；无 id 的超限通知本地拒绝。
public enum DialoutOutboundFrameBuildResult {
    case frame(Data)
    case rejectUpstream(String)
    case dropped
}

public enum DialoutOutboundFrameBuilder {
    public static func build(line: String, session: SecureSession,
                             maxBytes: Int = RelayWireLimits.maxMessageBytes) throws
        -> DialoutOutboundFrameBuildResult {
        let original = try encode(line: line, session: session)
        guard original.count > maxBytes else { return .frame(original) }
        guard let classification = classifyOversized(line) else { return .dropped }
        let rejection = classification.rejection
        if classification.isServerRequest { return .rejectUpstream(rejection) }
        let compact = try encode(line: rejection, session: session)
        return compact.count <= maxBytes ? .frame(compact) : .dropped
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
