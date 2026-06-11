import SwiftUI

@main
struct CodexRemoteApp: App {
    // Stores 在 App 持有（@State 保证生命周期），注入 environment 供全树访问。
    // 生产传 liveTransportFactory（SSH + codex app-server exec proxy）。
    @State private var connection = ConnectionStore(transportFactory: liveTransportFactory)
    @State private var projects = ProjectsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .environment(projects)
        }
    }
}

/// 正式根视图：未连接（ready/reconnecting 之外）展示连接配置；连接就绪后切到三栏骨架。
/// 重连中顶部叠加横幅，但保留三栏可见（不打断浏览）。
/// 注：SpikeView（Task 3 临时握手验证视图）保留在 Spike/ 目录，不再作为根视图。
struct RootView: View {
    @Environment(ConnectionStore.self) private var connection

    var body: some View {
        Group {
            switch connection.phase {
            case .ready, .reconnecting:
                RootSplitView()
            default:
                NavigationStack { ConnectionConfigView() }
            }
        }
        .overlay(alignment: .top) { reconnectBanner }
    }

    @ViewBuilder private var reconnectBanner: some View {
        if connection.phase == .reconnecting {
            Text("重连中…")
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.yellow.opacity(0.3), in: Capsule())
                .padding(.top, 8)
        }
    }
}
