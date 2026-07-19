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
    }

    func updateMachine(_ m: MachineConfig) { machine = m }
    func connect() { connection.connect(config: machine.connectionConfig) }
    func disconnect() async { await connection.disconnect() }
}
