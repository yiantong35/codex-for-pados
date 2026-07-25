import Foundation

/// relay-dialout CLI 命令（撤销信任 / 列出 / 正常拨号）。
public enum TrustCommand: Equatable, Sendable {
    case forget(labelOrPubPrefix: String)
    case forgetAll
    case list
    case runDialout
    case invalid(String)
}

/// 解析 argv（不含程序名）为 TrustCommand。纯函数，便于单测。
public func parseTrustCommand(_ args: [String]) -> TrustCommand {
    guard let first = args.first else { return .runDialout }
    switch first {
    case "--forget":
        guard args.count >= 2, !args[1].isEmpty else {
            return .invalid("--forget 需要一个 label 或公钥前缀参数")
        }
        return .forget(labelOrPubPrefix: args[1])
    case "--forget-all":
        return .forgetAll
    case "--list-trusted":
        return .list
    default:
        return .runDialout
    }
}
