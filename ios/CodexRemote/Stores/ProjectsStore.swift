import Foundation
import Observation

/// 一个「项目」= 同一 cwd 下的会话集合。左栏按项目分组展示。
struct Project: Identifiable {
    var id: String { cwd }
    let cwd: String
    var threads: [ThreadSummary]
    var displayName: String { (cwd as NSString).lastPathComponent }
}

/// 状态层：拉取 `thread/list`，按 cwd 分组为项目，并维护「待批准」徽标集合。
@Observable
@MainActor
final class ProjectsStore {
    private(set) var projects: [Project] = []
    private var pendingApproval: Set<String> = []

    /// session-management「桌面来源会话可见」：默认 sourceKinds 可能不含桌面 app（appServer）来源，
    /// 显式覆盖以确保桌面会话出现（设计 §13 Open Question，build 实测确认；不含也无害）。
    /// 真实 ThreadSourceKind 字符串值见 protocol/ts/v2/ThreadSourceKind.ts，桌面来源为 "appServer"。
    static func listParamsForDesktopVisibility() -> ThreadListParams {
        ThreadListParams(cursor: nil,
                         limit: 100,
                         sourceKinds: ["cli", "vscode", "exec", "appServer"],
                         cwd: nil,
                         searchTerm: nil,
                         archived: nil)
    }

    /// 从服务端拉取并 ingest。失败静默（保留旧 projects）。
    func loadFromServer(rpc: JSONRPCClient) async {
        let params = Self.listParamsForDesktopVisibility()
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let result = try? await rpc.send(method: RPCMethod.threadList, params: any),
              let resData = try? JSONEncoder().encode(result),
              let resp = try? JSONDecoder().decode(ThreadListResponse.self, from: resData)
        else { return }
        ingest(resp.data)
    }

    /// 按 cwd 分组：每组内按 updatedAt 倒序，组间按 cwd 升序，输出稳定。
    func ingest(_ threads: [ThreadSummary]) {
        let grouped = Dictionary(grouping: threads, by: \.cwd)
        projects = grouped.map { cwd, ts in
            Project(cwd: cwd, threads: ts.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { $0.cwd < $1.cwd }
    }

    func setPendingApproval(threadId: String, pending: Bool) {
        if pending { pendingApproval.insert(threadId) } else { pendingApproval.remove(threadId) }
    }

    func hasPendingApproval(_ threadId: String) -> Bool { pendingApproval.contains(threadId) }
}
