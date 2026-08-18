import SwiftUI

@main
struct CodexRemoteApp: App {
    // 多连接根：SessionsManager 持机器列表 + 每机器一个 Session（散 store 聚合）。
    // 方案②：根据活跃 Session 在 workspace 层注入该连接的散 store，读取点写法零改动。
    // 生产传 liveTransportFactory（经 SSH+proxy 接共享 daemon，密钥由 KeyManager 提供）。
    @State private var sessions = SessionsManager(
        machineStore: MachineStore(),
        transportFactory: liveTransportFactory)
    // appearance-locale：语言/主题 manager 在根持有并注入；驱动运行时切换。
    @State private var localeManager = LocaleManager()
    @State private var themeManager = ThemeManager()
    // T10：全局快捷键注册中心（设置页与主界面共享同一实例）。
    @State private var shortcuts = ShortcutStore()
    // #1：远端终端 OSC 52 写剪贴板门控（默认关闭，fail-closed）。根持有并注入，设置页与终端共享。
    @State private var clipboardPolicy = ClipboardPolicyStore()
    // global-text-scaling：全局文字缩放 manager，根持有并注入。
    @State private var textScale = TextScaleManager()

    init() {
        Self.purgeLegacySSHKeyOnce()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sessions)
                .environment(localeManager)
                .environment(themeManager)
                .environment(shortcuts)
                .environment(clipboardPolicy)
                .environment(textScale)
                // 运行时换语言：注入选定 locale，所有 Text(LocalizedStringKey) 跟随刷新。
                .environment(\.locale, localeManager.locale)
                // 运行时换主题：nil = 跟随系统。
                .preferredColorScheme(themeManager.colorScheme)
                // 运行时换字号：跟随系统(nil)不注入，覆盖档注入 .dynamicTypeSize（条件修饰）。
                .modifier(AppDynamicTypeSizeModifier(size: textScale.overrideSize))
                // 冷启动只连上次活跃机器（D7）；其余懒连。
                .task { sessions.bootstrapAutoConnect() }
        }
    }

    /// 一次性清理旧 SSH 私钥（SSH 传输层已移除）。幂等、非阻断：
    /// KeychainStore.delete 对 not-found 已按成功处理；仅真正 OSStatus 错误进 catch，
    /// 只记日志不 fail-closed 阻断启动（清理失败不比保留现状更差）。
    /// account/service 精确 scoped，绝不误删 relay 密钥（relay 用独立 service com.codexremote.relay-e2e）。
    private static func purgeLegacySSHKeyOnce() {
        do {
            try KeychainStore(service: "com.codexremote.ssh").delete("ssh-ed25519-private-key")
        } catch {
            NSLog("purgeLegacySSHKey: %@", String(describing: error))
        }
    }
}

/// 正式根视图：按机器列表 + 活跃 Session gating。
/// - 无机器 → OnboardingView 引导页（点「添加第一台机器」弹 MachineFormView）。
/// - 有活跃 Session → workspace（方案②注入该 Session 的散 store + `.id` 强制切 tab 重建子树）。
struct RootView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.scenePhase) private var scenePhase   // D1：app 级前后台唯一来源

    var body: some View {
        // @Bindable 桥接 addMachinePresented，供 sheet 双向绑定（引导态/主界面共用一个稳定挂载层）。
        @Bindable var sessions = sessions
        Group {
            if sessions.machineStore.machines.isEmpty {
                OnboardingView()
            } else if let s = sessions.activeSession {
                workspace(for: s)
            } else {
                // machines 非空但无 activeSession（近乎不可达）：回落引导页，仍可加/切机器。
                OnboardingView()
            }
        }
        // sheet 挂在 RootView（稳定层）：无论引导态还是主界面点 [+]/「添加第一台机器」都能弹出。
        .sheet(isPresented: $sessions.addMachinePresented) { MachineFormView() }
        // 能耗（D1）：app 级前后台唯一来源。广播给全部缓存 Session 的 transport
        //（→ 后台暂停重连/握手、回前台恢复）。与 tab 级轮询开关正交。
        .onChange(of: scenePhase) { _, phase in
            sessions.setAppForegroundAll(phase == .active)
        }
    }

    /// 方案②：注入当前 Session 的散 store，读取点（Sidebar/Conversation/… 的
    /// `@Environment(XxxStore.self)`）写法保持不变；`.id(s.id)` 强制切 tab 重建整棵子树
    /// （连同 WorkspaceHost 的 approval coordinator 一起重建，避免跨连接串台）。
    @ViewBuilder private func workspace(for s: Session) -> some View {
        WorkspaceHost(workspaceState: s.workspaceState)
            .environment(s.connection)
            .environment(s.projects)
            .environment(s.approvals)
            .environment(s.userInputs)
            .environment(s.mcpElicitations)
            .environment(s.environment)
            .environment(s.mcp)
            .environment(s.skills)
            .environment(s.plugins)
            .environment(s.hooks)
            .environment(s.terminal)
            // 右栏直接消费 Session 持有的 store；面板隐藏、inline/overlay 切换不销毁浏览与侧聊状态。
            .environment(s.fileBrowser)
            .environment(s.sideChat)
            .environment(s.envInspector)
            .id(s.id)
    }
}

/// 工作区宿主：承接从旧 RootView 迁来的 approval coordinator 接线。
/// 它读的是**当前 Session** 的 connection/projects/approvals（方案②由 workspace(for:) 注入），
/// 故 coordinator 绑定到当前连接的 rpc；`.id(s.id)` 挂在本视图 → 切 Session 时 coordinator 一并重建。
private struct WorkspaceHost: View {
    let workspaceState: WorkspaceSessionState
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @Environment(ApprovalStore.self) private var approvals
    @Environment(UserInputStore.self) private var userInputs
    @Environment(McpElicitationStore.self) private var mcpElicitations
    @Environment(FileBrowserStore.self) private var fileBrowser
    @State private var coordinator: ApprovalCoordinator?
    @State private var userInputCoordinator: UserInputCoordinator?
    @State private var mcpElicitationCoordinator: McpElicitationCoordinator?
    var body: some View {
        // TabBarView 已上提到 RootView（`.id(s.id)` 外层，常驻不重建）；本视图只承接
        // RootSplitView + coordinator 接线。切 tab 由外层 `.id(s.id)` 重建本子树。
        RootSplitView(workspaceState: workspaceState)
            // 连接就绪/重连成功后把交互请求层接到当前 rpc；断线时标记待恢复（绝不自动批准）。
            // 用 `.task(id:)` 而非 `.onChange`：`.id(s.id)` 重建 WorkspaceHost 时 @State coordinator 归 nil，
            // 若切到已连接的缓存 Session，rpcIdentity 初值即为该 rpc id（无变化）→ onChange 不触发 →
            // 该 tab 审批层不再绑定。`.task(id:)` 在 `.id` 重建即重跑（bind 幂等：内部先 cancel 旧订阅 Task），
            // 绑定 key 同时包含 ready 状态，使复用同一 RPC 的物理重连也会启动交互请求恢复窗口。
            .task(id: coordinatorBindingIdentity) {
                let coord = coordinator ?? ApprovalCoordinator(store: approvals, projects: projects)
                coordinator = coord
                let inputCoord = userInputCoordinator ?? UserInputCoordinator(store: userInputs)
                userInputCoordinator = inputCoord
                let mcpCoord = mcpElicitationCoordinator ?? McpElicitationCoordinator(store: mcpElicitations)
                mcpElicitationCoordinator = mcpCoord
                if connection.phase == .ready, let rpc = connection.rpc {
                    await coord.bind(rpc: rpc)
                    await inputCoord.bind(rpc: rpc)
                    await mcpCoord.bind(rpc: rpc)
                }
            }
            .onChange(of: connection.phase) { _, phase in
                if phase != .ready {
                    coordinator?.connectionLost()
                    userInputCoordinator?.connectionLost()
                    mcpElicitationCoordinator?.connectionLost()
                    fileBrowser.handleConnectionLost()
                }
            }
    }

    /// rpc 实例变化的探测键（ObjectIdentifier 字符串），用于在(重)连后重新 bind。
    private var rpcIdentity: String {
        connection.rpc.map { "\(ObjectIdentifier($0))" } ?? "nil"
    }

    /// Physical reconnects reuse the JSONRPCClient, so readiness must also invalidate the binding task.
    private var coordinatorBindingIdentity: String {
        "\(rpcIdentity):\(connection.phase == .ready ? "ready" : "not-ready")"
    }

}
