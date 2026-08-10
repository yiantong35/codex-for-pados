import Foundation

/// 文件只读预览内容（D4 降级结果）。
enum FileContent: Equatable {
    case text(String)
    case image(Data)
    case tooLarge
    case binary(Data)
}

/// 文件内容降级判定（纯逻辑，单测覆盖三分支）。
enum FileContentDecoder {
    /// 大小上限：512KB（字节）。
    static let maxBytes = 512 * 1024

    /// 从已解码字节判定内容类别。顺序：过大 → 二进制(NUL/非UTF8) → 文本。
    static func classify(bytes: Data) -> FileContent {
        if bytes.count > maxBytes { return .tooLarge }
        if isImage(bytes) { return .image(bytes) }
        // NUL 是合法 UTF-8，String(data:.utf8) 不会因它失败，须显式判为二进制。
        if bytes.contains(0x00) { return .binary(bytes) }
        guard let s = String(data: bytes, encoding: .utf8) else { return .binary(bytes) }
        return .text(s)
    }

    /// 从 base64 字符串解码后判定；base64 本身非法则视为不可预览的二进制。
    static func classify(base64: String) -> FileContent {
        guard let decodedByteCount = decodedByteCountIfValid(base64) else { return .binary(Data()) }
        // JSON 解码已经持有 base64 字符串；先用编码长度判限，避免超限文件再产生一份
        // 最多约为编码体积 3/4 的 Data 峰值；所有类型统一执行 512 KiB 规格上限。
        if decodedByteCount > maxBytes { return .tooLarge }
        guard let data = Data(base64Encoded: base64) else { return .binary(Data()) }
        return classify(bytes: data)
    }

    /// 严格校验标准 base64，并在不解码内容的情况下计算原始字节数。
    private static func decodedByteCountIfValid(_ base64: String) -> Int? {
        var count = 0
        var padding = 0
        var sawPadding = false

        for byte in base64.utf8 {
            count += 1
            switch byte {
            case 65...90, 97...122, 48...57, 43, 47: // A-Z a-z 0-9 + /
                if sawPadding { return nil }
            case 61: // =
                sawPadding = true
                padding += 1
                if padding > 2 { return nil }
            default:
                return nil
            }
        }

        guard count.isMultiple(of: 4) else { return nil }
        return (count / 4) * 3 - padding
    }

    private static func isImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || bytes.starts(with: Array("GIF8".utf8))
            || (bytes.count >= 12 && String(bytes: bytes[4..<12], encoding: .ascii)?.contains("ftyp") == true)
    }
}
