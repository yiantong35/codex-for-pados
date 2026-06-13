import Foundation

/// 摘要浮层 P0 数据的派生纯函数集合（无 SwiftUI 依赖，便于单测）。
/// 数据源：ConversationState（diff 行数 / 命令任务 / plan）+ ThreadSummary（cwd）。
enum WorkspaceSummary {

    /// 全会话 diff 行数汇总（来自所有 .fileChange item 的 added/removed）。
    struct DiffLineCounts: Equatable {
        var added: Int
        var removed: Int
        var changedFiles: Int
        var isEmpty: Bool { changedFiles == 0 }
    }

    static func diffLineCounts(in state: ConversationState) -> DiffLineCounts {
        var added = 0, removed = 0, files = 0
        for item in state.items {
            if case .fileChange(_, _, let a, let r, _) = item {
                added += a; removed += r; files += 1
            }
        }
        return DiffLineCounts(added: added, removed: removed, changedFiles: files)
    }
}
