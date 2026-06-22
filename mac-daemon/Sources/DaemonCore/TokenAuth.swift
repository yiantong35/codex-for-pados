import Foundation

/// 预共享 token 鉴权:从 WS 握手 URI 的 query 参数提取并校验 token。
public enum TokenAuth {
    /// 从 URI(如 `/?token=abc` 或 `/ws?foo=1&token=abc`)提取 token 值。
    /// 无 query 或无 `token` 参数返回 nil;`token=` 返回空串。
    public static func extractToken(fromURI uri: String) -> String? {
        guard let q = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: q)...]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.first == "token" {
                return kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return nil
    }

    /// 校验:expected 非空,且 URI 中 token 与之相等才放行。
    public static func authorize(uri: String, expected: String) -> Bool {
        guard !expected.isEmpty, let token = extractToken(fromURI: uri) else { return false }
        return token == expected
    }
}
