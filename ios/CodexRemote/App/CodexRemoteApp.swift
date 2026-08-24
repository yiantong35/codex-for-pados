import SwiftUI
import UIKit

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
                // 关键：把主题落到 UIWindow.overrideUserInterfaceStyle。
                // SwiftUI 的 .preferredColorScheme 只作用于当前 hosting controller，
                // **模态 sheet（独立 hosting controller）首帧不继承**——sheet 先用窗口默认外观渲染，
                // 一个 runloop 后 sheet 内自带的 .preferredColorScheme 才落地、触发 trait 变更重排，
                // 表现为分组 List「黑底→灰底」中间态（真机实证）。窗口级 override 会同步传播到
                // 该窗口 VC 层级下的所有已呈现 sheet，首帧即正确 → 消除中间态。
                .onAppear { Self.applyWindowInterfaceStyle(themeManager.theme) }
                .onChange(of: themeManager.theme) { _, t in Self.applyWindowInterfaceStyle(t) }
                // 运行时换字号：跟随系统(nil)不注入，覆盖档注入 .dynamicTypeSize（条件修饰）。
                .modifier(AppDynamicTypeSizeModifier(size: textScale.overrideSize))
                // 把 app 字号档同步到窗口 trait，使系统级 UIMenu（机器切换弹窗）等 UIKit 呈现界面也跟随。
                // 与上面 SwiftUI 端 clamp 恒定落同一档、不叠加放大（见 applyWindowContentSizeCategory 注释）。
                .onAppear { Self.applyWindowContentSizeCategory(textScale.overrideSize) }
                .onChange(of: textScale.overrideSize) { _, s in Self.applyWindowContentSizeCategory(s) }
                // 冷启动只连上次活跃机器（D7）；其余懒连。
                .task { sessions.bootstrapAutoConnect() }
        }
    }

    /// 把 App 主题落到当前所有前台窗口的 `overrideUserInterfaceStyle`，使模态 sheet 首帧即用正确外观
    /// （规避 sheet 不继承 SwiftUI `.preferredColorScheme` 导致的「黑底→灰底」中间态）。
    /// `.system` → `.unspecified`（跟随系统，系统外观变化时窗口自动跟随，无需再处理）。
    private static func applyWindowInterfaceStyle(_ theme: AppTheme) {
        let style: UIUserInterfaceStyle
        switch theme {
        case .system: style = .unspecified
        case .light:  style = .light
        case .dark:   style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState != .background else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// 把 App 文字大小档落到当前所有前台窗口的 `traitOverrides.preferredContentSizeCategory`，
    /// 使**系统级 UIKit 呈现界面**（机器切换的系统 `Menu`、alert、context menu 等）也跟随 app 字号。
    ///
    /// 为什么需要：SwiftUI 的 `.dynamicTypeSize`（AppDynamicTypeSizeModifier）只作用于 SwiftUI 内容树，
    /// **不写回 UIWindow 的 UITraitCollection**；而系统 UIMenu 由 UIKit 依呈现上下文的 trait 渲染，
    /// 故此前只认 iOS 系统字号、无视 app 内「文字大小」。窗口级 trait 覆盖填平这一缺口。
    ///
    /// 不会与 SwiftUI 端叠加放大：`.dynamicTypeSize(size...size)` 是**钳制**（输出恒为 size），
    /// 无论入参 trait 为何都落到同一档 → SwiftUI 内容与系统 Menu 同档、不双重缩放。
    /// `.system`(nil) → `.unspecified`：清除覆盖、放行系统 Dynamic Type（与 SwiftUI 端全范围放行一致）。
    private static func applyWindowContentSizeCategory(_ size: DynamicTypeSize?) {
        let category = contentSizeCategory(for: size)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState != .background else { continue }
            for window in windowScene.windows {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        }
    }

    /// `DynamicTypeSize?` → `UIContentSizeCategory`。nil → `.unspecified`（不覆盖，放行系统档）。
    /// 全枚举覆盖 + `@unknown default` 兜底：即便 overrideSize 未来扩档也不静默错映。
    private static func contentSizeCategory(for size: DynamicTypeSize?) -> UIContentSizeCategory {
        guard let size else { return .unspecified }
        switch size {
        case .xSmall:         return .extraSmall
        case .small:          return .small
        case .medium:         return .medium
        case .large:          return .large
        case .xLarge:         return .extraLarge
        case .xxLarge:        return .extraExtraLarge
        case .xxxLarge:       return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default:     return .unspecified
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
        // @Bindable 桥接 addMachinePresented，供 sheet 双向绑定。
        @Bindable var sessions = sessions
        // 用 ZStack（真容器）而非 Group 承载分支：Group 会把 .sheet 透传到「每个子分支」
        // 各自附加，分支一旦切换（断开态后台重连令 activeSession 抖动→引导/工作区互换）
        // 就销毁当前承载分支、连带把配对 sheet 自动收回（用户实测：点扫码/粘贴弹窗自己收回）。
        // ZStack 是单一稳定视图，sheet 附着其上，内部分支切换不再牵连 sheet 生命周期。
        ZStack {
            if sessions.machineStore.machines.isEmpty {
                OnboardingView()
            } else if let s = sessions.activeSession {
                workspace(for: s)
            } else {
                // machines 非空但无 activeSession（近乎不可达）：回落引导页，仍可加/切机器。
                OnboardingView()
            }
        }
        // sheet 挂在稳定的 ZStack 容器：无论引导态还是主界面点 [+]/「添加第一台机器」都能弹出，
        // 且分支切换不再误收回。
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
