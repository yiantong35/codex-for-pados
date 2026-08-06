import Foundation
import Observation

/// 文件浏览状态层（只读）：以选中 thread 的 cwd 为根，懒加载目录树、缓存每层结果、
/// 读取文件内容并按 D4 降级。独立于 ConversationStore，模式同 EnvironmentStore（attach(rpc:) 自发请求）。
@Observable
@MainActor
final class FileBrowserStore {
    /// 目录节点缓存条目。entries == nil 表示尚未加载。
    struct DirNode {
        var entries: [FsReadDirectoryEntry]?
        var isExpanded: Bool
        var isLoading: Bool
        var error: String?
    }

    /// 当前选中的文件（只读预览）。
    struct SelectedFile: Equatable {
        let path: String
        let content: FileContent
    }

    enum FileOpenState: Equatable {
        case idle
        case loading(String)
        case loaded(SelectedFile)
        case failed(String)
    }

    private(set) var rootPath: String?
    /// 路径 → 目录节点缓存。
    private(set) var nodes: [String: DirNode] = [:]
    /// 当前选中的文件内容（只读预览）。
    private(set) var fileOpenState: FileOpenState = .idle
    var selectedFile: SelectedFile? {
        guard case .loaded(let file) = fileOpenState else { return nil }
        return file
    }
    var isOpeningFile: Bool {
        if case .loading = fileOpenState { return true }
        return false
    }

    private var rpc: JSONRPCClient?

    /// 无根路径（无 cwd）即空态。
    var isEmpty: Bool { rootPath == nil }

    /// 注入 rpc（幂等）。无初始拉取——由 setRoot 触发。
    func attach(rpc: JSONRPCClient) { self.rpc = rpc }

    /// 设根路径 = 当前 cwd。清空缓存与选中文件；非空则拉根，空则进空态不发请求。
    /// async：调用方 await 到根加载完成。thread 切换（cwd 变化）驱动的重叠 setRoot 不做
    /// 硬串行——被 .task(id:) 取消的旧 setRoot 迟到写入会落在旧 rootPath 的 key 下，而每次
    /// setRoot 先 removeAll 并改写 rootPath，树只从当前 rootPath 渲染，故陈旧写入是不可达
    /// 孤儿、由下次 removeAll 回收，无可见错误。（若未来需精确取消，可引入 attempt token。）
    func setRoot(_ cwd: String?) async {
        nodes.removeAll()
        fileOpenState = .idle
        rootPath = cwd
        guard let cwd else { return }
        await loadDirectory(cwd, expand: true)
    }

    /// 展开/收起目录。未加载则拉取并缓存；已加载再展开复用缓存不重拉。
    func toggleExpand(_ path: String) async {
        if var node = nodes[path], node.entries != nil {
            node.isExpanded.toggle()
            nodes[path] = node
            return
        }
        await loadDirectory(path, expand: true)
    }

    /// 手动刷新：清空全部缓存、收起所有层、重拉根（D3）。
    func refresh() async {
        nodes.removeAll()
        guard let root = rootPath else { return }
        await loadDirectory(root, expand: true)
    }

    /// 选中文件：拉 fs/readFile → 降级 → 存 selectedFile。
    /// 进入时置 isOpeningFile 并清空旧 selectedFile（避免预览区停留在上一个文件）；
    /// 返回（成功/失败降级）后复位（设计文档 D，与目录 loading 模式一致）。
    func openFile(_ path: String) async {
        fileOpenState = .loading(path)
        guard let resp: FsReadFileResponse = await send(
            RPCMethod.fsReadFile, FsReadFileParams(path: path), as: FsReadFileResponse.self) else {
            fileOpenState = .failed(path)
            return
        }
        fileOpenState = .loaded(SelectedFile(
            path: path,
            content: FileContentDecoder.classify(base64: resp.dataBase64)))
    }

    // MARK: - private

    /// 拉一层目录，写入缓存（含加载/错误态）。expand 决定拉后是否展开。
    private func loadDirectory(_ path: String, expand: Bool) async {
        var node = nodes[path] ?? DirNode(entries: nil, isExpanded: false, isLoading: false, error: nil)
        node.isLoading = true
        node.error = nil
        nodes[path] = node

        let resp: FsReadDirectoryResponse? = await send(
            RPCMethod.fsReadDirectory, FsReadDirectoryParams(path: path), as: FsReadDirectoryResponse.self)

        node.isLoading = false
        if let resp {
            node.entries = resp.entries
            node.isExpanded = expand
        } else {
            node.error = L10n.string("fileBrowser.loadDirFailed", locale: LocaleManager.currentLocale)
        }
        nodes[path] = node
    }

    /// Encodable 参数 → AnyCodable → rpc.send → 解成强类型；失败返回 nil（同 fetchFullDiff 降级）。
    private func send<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type) async -> R? {
        guard let rpc,
              let d = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: d),
              let res = try? await rpc.send(method: method, params: any),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(R.self, from: rd) else { return nil }
        return out
    }
}
