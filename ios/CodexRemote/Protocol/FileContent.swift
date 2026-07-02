import Foundation

/// 文件只读预览内容（D4 降级结果）。
enum FileContent: Equatable {
    case text(String)
    case tooLarge
    case binary
}

/// 文件内容降级判定（纯逻辑，单测覆盖三分支）。
enum FileContentDecoder {
    /// 大小上限：512KB（字节）。
    static let maxBytes = 512 * 1024

    /// 从已解码字节判定内容类别。顺序：过大 → 二进制(NUL/非UTF8) → 文本。
    static func classify(bytes: Data) -> FileContent {
        if bytes.count > maxBytes { return .tooLarge }
        // NUL 是合法 UTF-8，String(data:.utf8) 不会因它失败，须显式判为二进制。
        if bytes.contains(0x00) { return .binary }
        guard let s = String(data: bytes, encoding: .utf8) else { return .binary }
        return .text(s)
    }

    /// 从 base64 字符串解码后判定；base64 本身非法则视为不可预览的二进制。
    static func classify(base64: String) -> FileContent {
        guard let data = Data(base64Encoded: base64) else { return .binary }
        return classify(bytes: data)
    }
}
