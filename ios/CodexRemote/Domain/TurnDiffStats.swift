import Foundation

/// 解析整 turn 聚合 unified diff，得出增删行数 / 变更文件数 / 文件名列表。
/// 纯函数，无 SwiftUI 依赖，便于单测。是 +A−B、文件数、change3 逐行 diff 的唯一真相源。
enum TurnDiffStats {
    struct Stats: Equatable {
        var added: Int = 0
        var removed: Int = 0
        var changedFiles: Int = 0
        var files: [String] = []
        var isEmpty: Bool { changedFiles == 0 }
    }

    /// 规则：
    /// - `diff --git a/<old> b/<new>` 开启一个文件块，文件数 +1
    /// - 数据行 `+`/`-` 计增删，但排除文件头 `+++`/`---`
    /// - `@@` hunk 头、`\ No newline…`、similarity/index/mode 等元行忽略
    /// - 文件名优先用新路径（`+++ b/<path>`）；删除（`+++ /dev/null`）用旧路径（`--- a/<path>`）；
    ///   重命名（`rename to <path>`）用新路径；二进制（`Binary files … differ`）从 `diff --git` 头取
    static func parse(_ diff: String) -> Stats {
        var s = Stats()
        // 当前文件块的候选名（按优先级覆盖）
        var gitOldPath: String?     // 来自 diff --git a/<old>
        var gitNewPath: String?     // 来自 diff --git b/<new>
        var headerNewPath: String?  // 来自 +++ b/<path>（非 /dev/null）
        var headerOldPath: String?  // 来自 --- a/<path>（非 /dev/null）
        var renamePath: String?     // 来自 rename to <path>

        func flushFile() {
            guard gitOldPath != nil || gitNewPath != nil else { return }
            let name = renamePath
                ?? headerNewPath
                ?? gitNewPath
                ?? headerOldPath
                ?? gitOldPath
                ?? ""
            s.files.append(name)
            s.changedFiles += 1
            gitOldPath = nil; gitNewPath = nil
            headerNewPath = nil; headerOldPath = nil; renamePath = nil
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                // 形如：diff --git a/old b/new
                let parts = line.dropFirst("diff --git ".count).split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    gitOldPath = stripPrefix(String(parts[0]))   // a/old
                    gitNewPath = stripPrefix(String(parts[1]))   // b/new
                }
                continue
            }
            if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4))
                if p != "/dev/null" { headerNewPath = stripPrefix(p) }
                continue   // 文件头不计增删
            }
            if line.hasPrefix("--- ") {
                let p = String(line.dropFirst(4))
                if p != "/dev/null" { headerOldPath = stripPrefix(p) }
                continue
            }
            if line.hasPrefix("rename to ") {
                renamePath = String(line.dropFirst("rename to ".count))
                continue
            }
            if line.hasPrefix("@@") || line.hasPrefix("\\ ") { continue }
            if line.hasPrefix("+") { s.added += 1; continue }
            if line.hasPrefix("-") { s.removed += 1; continue }
            // 其它元行（index/mode/similarity/Binary/上下文行）忽略
        }
        flushFile()
        return s
    }

    /// 剥 `a/`、`b/` 前缀（git diff 路径约定）。
    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }
}
