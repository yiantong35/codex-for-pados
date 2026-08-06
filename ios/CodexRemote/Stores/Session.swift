import Foundation
import Observation

/// 单台机器的「会话世界」：聚合该连接的 ConnectionStore 与全部功能 store。
/// 每台机器一个 Session（SessionsManager 缓存保活）；store 实例彼此隔离，切 tab 不串台。
@Observable
@MainActor
final class Session: Identifiable {
    let id: UUID
    private(set) var machine: MachineConfig

    let connection: ConnectionStore
    let projects: ProjectsStore
    let environment: EnvironmentStore
    let mcp: McpStore
    let skills: SkillsStore
    let plugins: PluginsStore
    let hooks: HooksStore
    let terminal: TerminalSession
    let fileBrowser: FileBrowserStore
    let sideChat: SideChatStore
    let envInspector: EnvironmentInspectorModel
    let approvals: ApprovalStore
    let userInputs: UserInputStore

    init(machine: MachineConfig,
         transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.id = machine.id
        self.machine = machine
        self.connection = ConnectionStore(transportFactory: transportFactory)
        self.projects = ProjectsStore()
        self.environment = EnvironmentStore()
        self.mcp = McpStore()
        self.skills = SkillsStore()
        self.plugins = PluginsStore()
        self.hooks = HooksStore()
        self.terminal = TerminalSession()
        self.fileBrowser = FileBrowserStore()
        self.sideChat = SideChatStore()
        self.envInspector = EnvironmentInspectorModel()
        self.approvals = ApprovalStore()
        self.userInputs = UserInputStore()
    }

    /// 前后台标记（D6=B）。默认后台；活跃 tab 由 SessionsManager 置前台。
    private(set) var isForeground = false

    /// 是否应发起（重）连：未在连接中且未就绪。用于切 tab 懒连（D7）与 tab 菜单重连入口。
    /// `.failed`/`.disconnected` → 可（重）连；`.connecting`/`.initializing`/`.reconnecting`/`.ready` → 不重复触发。
    var shouldAutoConnect: Bool {
        switch connection.phase {
        case .ready, .connecting, .initializing, .reconnecting: return false
        case .disconnected, .failed: return true
        }
    }

    func updateMachine(_ m: MachineConfig) { machine = m }
    func connect() { connection.connect(config: machine.connectionConfig) }
    func disconnect() async { await connection.disconnect() }

    /// 前后台切换（D6=B「后台保连+降频」）。
    /// 前台：开列表轮询 + 补拉最终态；后台：停轮询降频。
    /// A 类广播订阅（projects.attach 的 thread/status/changed）前后台都保留，徽标始终 live；
    /// 会话正文 delta（B 类）由 per-thread ConversationStore 承载，后台 tab 未打开会话本就无订阅，
    /// 故此处无需额外退订正文——Session 级唯一 lever 就是列表轮询开关。
    func setForeground(_ v: Bool) {
        isForeground = v
        if v {
            projects.startPolling()
            Task { await projects.refreshNow() }
        } else {
            projects.stopPolling()
        }
    }

    /// app 级前后台（能耗，D1）：与 tab 级 `setForeground`（轮询）**正交**——本方法**只**转发
    /// 给 connection（→ transport 暂停/恢复重连），绝不动 `isForeground` 与 `projects` 轮询。
    /// app 整体进/出系统后台时由 RootView 经 SessionsManager 广播给全部缓存 Session。
    func setAppForeground(_ active: Bool) {
        connection.setForeground(active)
    }
}
