import RelayProtocol

/// ws upgrade 请求的解析/校验(路由安全边界)。
///
/// 从 `/relay/{sessionId}` 路径 + `x-role` header 值提取撮合所需的
/// (sessionId, role)。任一不合法返回 nil = 拒绝 upgrade。
///
/// 纯函数,不碰 NIO,便于单测固化"拒绝畸形 sessionId/role"的边界。
public enum UpgradeRequest {
    /// 解析 upgrade 请求。
    /// - Parameters:
    ///   - uri: 请求 uri,形如 `/relay/{sessionId}`(可能带 `?query`)。
    ///   - role: header `x-role` 的值(缺失为 nil)。
    /// - Returns: 合法时返回 (sessionId, role);任一不合法返回 nil。
    public static func parseUpgrade(uri: String, role: String?) -> (sessionId: String, role: RelayPeer)? {
        // uri 去掉 query 后按 "/" 切段,要求恰为 ["relay", <非空 sessionId>]。
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count == 2, segments[0] == "relay", !segments[1].isEmpty else { return nil }
        let sessionId = segments[1]
        guard let roleRaw = role, let peer = RelayPeer(rawValue: roleRaw) else { return nil }
        return (sessionId, peer)
    }
}
