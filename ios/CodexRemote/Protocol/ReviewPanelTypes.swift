import Foundation

struct GitDiffToRemoteParams: Encodable { let cwd: String }
struct GitDiffToRemoteResponse: Decodable { let sha: String; let diff: String }

/// 审查面板数据源：一份 unified diff + 来源标签(+可选 cwd)。面板与来源解耦。
struct ReviewDiffSource: Equatable {
    let diff: String
    let label: String
    var cwd: String?
    var files: [DiffFile] { UnifiedDiffParser.parse(diff) }
    var isEmpty: Bool { files.isEmpty }
}

/// 数据源模式：本轮(当前 turn 的 turnDiff) / 全量(gitDiffToRemote 拉取的仓库全量 diff)。
enum ReviewSourceMode: CaseIterable, Identifiable {
    case turn, full
    var id: Self { self }
    var label: String { self == .turn ? "本轮" : "全量" }
}

extension ReviewDiffSource {
    /// 按模式把「本轮」与「全量」两份 diff 映射成面板数据源。全量未拉取(nil)→空 diff(面板显示空态)。
    static func resolve(mode: ReviewSourceMode, turnDiff: String, fullDiff: String?) -> ReviewDiffSource {
        switch mode {
        case .turn: return ReviewDiffSource(diff: turnDiff, label: mode.label, cwd: nil)
        case .full: return ReviewDiffSource(diff: fullDiff ?? "", label: mode.label, cwd: nil)
        }
    }
}
