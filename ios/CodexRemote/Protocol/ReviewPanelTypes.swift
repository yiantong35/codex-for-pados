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
