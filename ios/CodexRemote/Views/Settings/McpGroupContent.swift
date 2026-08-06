import SwiftUI

/// MCP 分组内容（设计 D1）：从旧 McpSettingsSectionView 抽出的可嵌入行内容，
/// 供 ExtensionsSectionView 的「MCP」Section 复用现有 McpStore。数据展示与 T4 完全一致，不退化。
struct McpGroupContent: View {
    @Environment(McpStore.self) private var mcp
    @Environment(ConnectionStore.self) private var connection

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        if !isReady {
            Text("settings.mcp.disconnected").foregroundStyle(.secondary)
        } else if mcp.loadState == .loading && mcp.servers.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        } else if mcp.loadState == .failed && mcp.servers.isEmpty {
            loadError
        } else if mcp.servers.isEmpty {
            Text("settings.mcp.empty").foregroundStyle(.secondary)
        } else {
            if mcp.loadState == .failed { loadError }
            ForEach(mcp.servers) { server in
                serverBlock(server)
            }
        }
    }

    private var loadError: some View {
        HStack {
            Label("settings.extensions.loadFailed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Spacer()
            Button("common.retry") { Task { await mcp.refresh() } }.minimumHitTarget44()
        }
    }

    @ViewBuilder
    private func serverBlock(_ server: McpServerStatus) -> some View {
        HStack {
            Text(server.name).font(.headline)
            Spacer()
            authBadge(server.authStatus)
        }
        HStack(alignment: .top) {
            Text("settings.mcp.tools").foregroundStyle(.secondary)
            Spacer()
            if server.tools.isEmpty {
                Text("settings.mcp.tools.none").foregroundStyle(.tertiary)
            } else {
                Text("\(server.tools.count)").foregroundStyle(.secondary)
            }
        }
        if !server.tools.isEmpty {
            Text(server.toolNames.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("settings.mcp.resources").foregroundStyle(.secondary)
            Spacer()
            Text("\(server.resources.count)").foregroundStyle(.secondary)
        }
    }

    private func authBadge(_ status: McpAuthStatus) -> some View {
        Text(authLabel(status))
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(authColor(status).opacity(0.15), in: Capsule())
            .foregroundStyle(authColor(status))
    }

    private func authLabel(_ status: McpAuthStatus) -> LocalizedStringKey {
        switch status {
        case .unsupported: return "settings.mcp.auth.unsupported"
        case .notLoggedIn: return "settings.mcp.auth.notLoggedIn"
        case .bearerToken: return "settings.mcp.auth.bearerToken"
        case .oAuth:       return "settings.mcp.auth.oauth"
        case .unknown:     return "settings.mcp.auth.unknown"
        }
    }

    private func authColor(_ status: McpAuthStatus) -> Color {
        switch status {
        case .bearerToken, .oAuth: return .green
        case .notLoggedIn:         return .orange
        case .unsupported:         return .secondary
        case .unknown:             return .secondary
        }
    }
}
