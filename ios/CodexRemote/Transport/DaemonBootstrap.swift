import Foundation

/// 缺口①纯逻辑：拼装官方 `codex app-server daemon start` / `proxy` 命令（含非交互 SSH PATH 前缀），
/// 并解析 `daemon start` 的 JSON 输出取 `socketPath`。不碰网络，全部可单测。
enum DaemonBootstrap {
    struct Result: Codable, Equatable {
        let status: String
        let socketPath: String
    }
    private static let pathPrefix =
        #"PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:/opt/homebrew/bin:/usr/local/bin:$PATH""#
    static var startCommand: String {
        "\(pathPrefix) codex app-server daemon start"
    }
    static func proxyCommand(sockPath: String) -> String {
        "\(pathPrefix) codex app-server proxy --sock \(shellSingleQuote(sockPath))"
    }
    /// POSIX 单引号包裹（#4）：抗路径中的空格/元字符。内嵌单引号用 `'\''` 技巧转义
    /// （关单引号 → 转义单引号 → 重开单引号），使结果始终是单个合法 shell 参数。
    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func parse(_ output: String) throws -> Result {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { continue }
            if let r = try? JSONDecoder().decode(Result.self, from: data) { return r }
        }
        throw TransportError.proxyFailed("daemon start 未返回可解析的 socketPath：\(output)")
    }
}
