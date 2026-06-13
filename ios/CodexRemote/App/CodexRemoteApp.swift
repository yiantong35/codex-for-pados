import SwiftUI

@main
struct CodexRemoteApp: App {
    // Stores 在 App 持有（@State 保证生命周期），注入 environment 供全树访问。
    // 生产传 liveTransportFactory（SSH + codex app-server exec proxy）。
    @State private var connection = ConnectionStore(transportFactory: liveTransportFactory)
    @State private var projects = ProjectsStore()
    @State private var approvals = ApprovalStore()
    // appearance-locale：语言/主题 manager 在根持有并注入；驱动运行时切换。
    @State private var localeManager = LocaleManager()
    @State private var themeManager = ThemeManager()
    // 连接密钥管理：app 内生成一次 ed25519 + 自动复用（生产用真 Keychain）。
    @State private var keyManager = KeyManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .environment(projects)
                .environment(approvals)
                .environment(localeManager)
                .environment(themeManager)
                .environment(keyManager)
                // 运行时换语言：注入选定 locale，所有 Text(LocalizedStringKey) 跟随刷新。
                .environment(\.locale, localeManager.locale)
                // 运行时换主题：nil = 跟随系统。
                .preferredColorScheme(themeManager.colorScheme)
        }
    }
}

/// 正式根视图：未连接（ready/reconnecting 之外）展示连接配置；连接就绪后切到三栏骨架。
/// 重连中顶部叠加横幅，但保留三栏可见（不打断浏览）。
struct RootView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @Environment(ApprovalStore.self) private var approvals
    @State private var coordinator: ApprovalCoordinator?

    var body: some View {
        Group {
            switch connection.phase {
            case .ready, .reconnecting:
                RootSplitView()
            default:
                // 连接界面已自带居中卡片布局与右上角齿轮 overlay，无需 NavigationStack 包裹。
                ConnectionConfigView()
            }
        }
        .overlay(alignment: .top) { reconnectBanner }
        // 连接就绪/重连成功后把审批层接到当前 rpc；断线（reconnecting）时标记待恢复（绝不自动批准）。
        .onChange(of: rpcIdentity) { _, _ in
            let coord = coordinator ?? ApprovalCoordinator(store: approvals, projects: projects)
            coordinator = coord
            if connection.phase == .ready, let rpc = connection.rpc {
                Task { await coord.bind(rpc: rpc) }
            }
        }
        .onChange(of: connection.phase) { _, phase in
            if phase == .reconnecting { coordinator?.connectionLost() }
        }
    }

    /// rpc 实例变化的探测键（ObjectIdentifier 字符串），用于在(重)连后重新 bind。
    private var rpcIdentity: String {
        connection.rpc.map { "\(ObjectIdentifier($0))" } ?? "nil"
    }

    @ViewBuilder private var reconnectBanner: some View {
        if connection.phase == .reconnecting {
            Text("root.reconnecting")
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.yellow.opacity(0.3), in: Capsule())
                .padding(.top, 8)
        }
    }
}
