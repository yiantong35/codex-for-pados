import Foundation

/// relay 地址 scheme 校验错误。
enum RelaySchemeError: Error, Equatable { case insecureScheme }

/// 生产强制 wss；ws 仅 loopback + DEBUG 放行（防明文暴露 sessionId/元数据、防连接被干扰）。
/// fail-closed：拿不准的 scheme/host 一律拒绝；生产构建下开发放行分支不存在。
enum RelaySchemeValidator {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    static func validate(url: URL) throws {
        switch url.scheme?.lowercased() {
        case "wss": return                                              // 加密：恒放行
        case "ws":
            #if DEBUG
            if let h = url.host, loopbackHosts.contains(h) { return }   // 仅开发 + loopback
            throw RelaySchemeError.insecureScheme
            #else
            throw RelaySchemeError.insecureScheme                        // 生产：明文一律拒
            #endif
        default:
            throw RelaySchemeError.insecureScheme                        // 未知/缺失 scheme：拒
        }
    }
}
