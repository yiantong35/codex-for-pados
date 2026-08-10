import Foundation

enum DiffLineKind { case add, del, context }
struct DiffLine: Equatable { let kind: DiffLineKind; let text: String; var oldLineNo: Int?; var newLineNo: Int? }
struct DiffHunk: Equatable { var lines: [DiffLine] }
enum DiffFileKind { case add, delete, modify, rename, binary }
struct DiffFile: Equatable, Identifiable {
    var path: String; var oldPath: String?; var kind: DiffFileKind; var hunks: [DiffHunk]
    var id: String { path }
}

/// 解析标准 git unified diff → 按文件的行级结构（纯客户端，供审查面板）。
enum UnifiedDiffParser {
    static func parse(_ diff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var curHunk: DiffHunk?
        var oldNo = 0, newNo = 0

        func closeHunk() { if let h = curHunk { cur?.hunks.append(h); curHunk = nil } }
        func closeFile() { closeHunk(); if let f = cur { files.append(f); cur = nil } }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("diff --git ") {
                closeFile()
                let paths = parseDiffHeader(String(raw.dropFirst("diff --git ".count)))
                cur = DiffFile(path: paths.map { stripPrefix($0.new) } ?? "",
                               oldPath: nil, kind: .modify, hunks: [])
            } else if raw.hasPrefix("rename from ") {
                cur?.oldPath = decodePathField(String(raw.dropFirst("rename from ".count))); cur?.kind = .rename
            } else if raw.hasPrefix("rename to ") {
                cur?.path = decodePathField(String(raw.dropFirst("rename to ".count))); cur?.kind = .rename
            } else if raw.hasPrefix("Binary files") {
                cur?.kind = .binary
            } else if raw.hasPrefix("--- ") {
                if decodePathField(String(raw.dropFirst(4))) == "/dev/null" { cur?.kind = .add }
            } else if raw.hasPrefix("+++ ") {
                let path = decodePathField(String(raw.dropFirst(4)))
                if path == "/dev/null" { cur?.kind = .delete }
                else { cur?.path = stripPrefix(path) } // +++ 是普通修改/新增文件的新路径权威来源
            } else if raw.hasPrefix("@@") {
                closeHunk()
                (oldNo, newNo) = parseHunkHeader(raw)
                curHunk = DiffHunk(lines: [])
            } else if curHunk != nil {
                if raw.hasPrefix("+") {
                    curHunk?.lines.append(DiffLine(kind: .add, text: String(raw.dropFirst()), oldLineNo: nil, newLineNo: newNo)); newNo += 1
                } else if raw.hasPrefix("-") {
                    curHunk?.lines.append(DiffLine(kind: .del, text: String(raw.dropFirst()), oldLineNo: oldNo, newLineNo: nil)); oldNo += 1
                } else if raw.hasPrefix(" ") || raw.isEmpty {
                    curHunk?.lines.append(DiffLine(kind: .context, text: raw.isEmpty ? "" : String(raw.dropFirst()), oldLineNo: oldNo, newLineNo: newNo)); oldNo += 1; newNo += 1
                }
                // 其它(\ No newline…)忽略
            }
        }
        closeFile()
        return files
    }

    private static func stripPrefix(_ s: String) -> String {
        if s.hasPrefix("a/") || s.hasPrefix("b/") { return String(s.dropFirst(2)) }
        return s
    }

    /// `diff --git` 的未引号路径允许空格，分隔点是最后一个 ` b/`；带特殊字符时 Git
    /// 使用 C-style quoted path，两边按 token 解码。
    private static func parseDiffHeader(_ payload: String) -> (old: String, new: String)? {
        if payload.hasPrefix("\"") {
            guard let first = parseQuotedToken(payload, from: payload.startIndex) else { return nil }
            var next = first.end
            while next < payload.endIndex, payload[next] == " " { next = payload.index(after: next) }
            guard next < payload.endIndex else { return nil }
            if payload[next] == "\"", let second = parseQuotedToken(payload, from: next) {
                return (first.value, second.value)
            }
            return (first.value, String(payload[next...]))
        }

        guard let separator = payload.range(of: " b/", options: .backwards) else { return nil }
        return (String(payload[..<separator.lowerBound]), String(payload[separator.lowerBound...].dropFirst()))
    }

    /// rename/---/+++ 字段：去掉可选时间戳，并解 Git C-style quoting。
    private static func decodePathField(_ field: String) -> String {
        let withoutTimestamp = field.split(separator: "\t", maxSplits: 1,
                                           omittingEmptySubsequences: false).first.map(String.init) ?? field
        guard withoutTimestamp.hasPrefix("\"") else { return withoutTimestamp }
        return parseQuotedToken(withoutTimestamp, from: withoutTimestamp.startIndex)?.value ?? withoutTimestamp
    }

    private static func parseQuotedToken(_ text: String, from start: String.Index)
        -> (value: String, end: String.Index)? {
        let bytes = Array(text.utf8)
        let byteOffset = text.utf8.distance(from: text.utf8.startIndex,
                                            to: start.samePosition(in: text.utf8)!)
        guard byteOffset < bytes.count, bytes[byteOffset] == 0x22 else { return nil }
        var index = byteOffset + 1
        var decoded: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let utf8End = text.utf8.index(text.utf8.startIndex, offsetBy: index + 1)
                return (String(decoding: decoded, as: UTF8.self), utf8End.samePosition(in: text)!)
            }
            guard byte == 0x5C else { decoded.append(byte); index += 1; continue }
            index += 1
            guard index < bytes.count else { return nil }
            let escaped = bytes[index]
            switch escaped {
            case 0x22, 0x5C: decoded.append(escaped); index += 1
            case 0x61: decoded.append(0x07); index += 1
            case 0x62: decoded.append(0x08); index += 1
            case 0x74: decoded.append(0x09); index += 1
            case 0x6E: decoded.append(0x0A); index += 1
            case 0x76: decoded.append(0x0B); index += 1
            case 0x66: decoded.append(0x0C); index += 1
            case 0x72: decoded.append(0x0D); index += 1
            case 0x30...0x37:
                var value = 0
                var digits = 0
                while index < bytes.count, digits < 3, (0x30...0x37).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 0x30)
                    index += 1; digits += 1
                }
                decoded.append(UInt8(truncatingIfNeeded: value))
            default:
                // Git 不定义的 escape 按被转义字节保留，避免静默丢字符。
                decoded.append(escaped); index += 1
            }
        }
        return nil
    }
    /// @@ -oldStart,oldCount +newStart,newCount @@
    private static func parseHunkHeader(_ line: String) -> (Int, Int) {
        // 取 -a 与 +c 的起始行号
        var old = 0, new = 0
        let toks = line.split(separator: " ")
        for t in toks {
            if t.hasPrefix("-") { old = Int(t.dropFirst().split(separator: ",").first ?? "0") ?? 0 }
            else if t.hasPrefix("+") { new = Int(t.dropFirst().split(separator: ",").first ?? "0") ?? 0 }
        }
        return (old, new)
    }
}
