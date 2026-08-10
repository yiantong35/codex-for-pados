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
    let mcpElicitations: McpElicitationStore
    let composerDrafts: ComposerDraftStore
    /// 与机器 Session 同寿命的工作区选择/面板上下文；切机器后返回时不复位。
    let workspaceState: WorkspaceSessionState

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
        self.mcpElicitations = McpElicitationStore()
        self.composerDrafts = ComposerDraftStore()
        self.workspaceState = WorkspaceSessionState()
    }

    /// 前后台标记（D6=B）。默认后台；活跃 tab 由 SessionsManager 置前台。
    private(set) var isForeground = false

    /// 兼容现有 UI/测试的暂停视图；真实意图持久化在 MachineConfig 中。
    var userPaused: Bool { connectionIntent == .disconnectedByUser }

    /// 是否应自动发起（重）连：用户未暂停，且当前未在连接中或就绪。
    /// `.failed`/`.disconnected` → 可（重）连；`.connecting`/`.initializing`/`.reconnecting`/`.ready` → 不重复触发。
    var shouldAutoConnect: Bool {
        guard connectionIntent == .automatic else { return false }
        return canConnect
    }

    /// 当前连接状态是否允许显式（重）连。用户暂停不隐藏 tab 菜单的连接入口。
    var canConnect: Bool {
        switch connection.phase {
        case .ready, .connecting, .initializing, .reconnecting: return false
        case .disconnected, .failed: return true
        }
    }

    var canConnectManually: Bool { canConnect }

    var connectionIntent: ConnectionIntent { machine.connectionIntent }

    func updateMachine(_ m: MachineConfig) { machine = m }
    func setConnectionIntent(_ intent: ConnectionIntent) { machine.connectionIntent = intent }
    func connect() {
        machine.connectionIntent = .automatic
        connection.connect(config: machine.connectionConfig)
    }
    func autoConnect() {
        guard shouldAutoConnect else { return }
        connection.connect(config: machine.connectionConfig)
    }
    func disconnect() async { await connection.disconnect() }

    /// 前后台切换（D6=B「后台保连+降频」）。
    /// 前台：开列表轮询 + 补拉最终态；后台：停轮询降频。
    /// A 类广播订阅（projects.attach 的 thread/status/changed）前后台都保留，徽标始终 live；
    /// 会话正文 delta（B 类）由 per-thread ConversationStore 承载，后台 tab 未打开会话本就无订阅，
    /// 故此处无需额外退订正文——Session 级唯一 lever 就是列表轮询开关。
    func setForeground(_ v: Bool) {
        isForeground = v
        connection.setTabActive(v)
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
