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
                // diff --git a/<old> b/<new>
                let parts = raw.dropFirst("diff --git ".count).split(separator: " ", maxSplits: 1)
                let newPath = parts.count == 2 ? stripPrefix(String(parts[1])) : ""
                cur = DiffFile(path: newPath, oldPath: nil, kind: .modify, hunks: [])
            } else if raw.hasPrefix("rename from ") {
                cur?.oldPath = String(raw.dropFirst("rename from ".count)); cur?.kind = .rename
            } else if raw.hasPrefix("rename to ") {
                cur?.path = String(raw.dropFirst("rename to ".count)); cur?.kind = .rename
            } else if raw.hasPrefix("Binary files") {
                cur?.kind = .binary
            } else if raw.hasPrefix("--- ") {
                if raw.contains("/dev/null") { cur?.kind = .add }
            } else if raw.hasPrefix("+++ ") {
                if raw.contains("/dev/null") { cur?.kind = .delete }
                else if let p = cur, p.path.isEmpty { cur?.path = stripPrefix(String(raw.dropFirst(4))) }
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
