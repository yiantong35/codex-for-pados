import SwiftUI

/// MCP 只读分区（设计 D1/D6）：展示当前 daemon 上的 MCP server + 一键 reload。
/// 生命周期随 connection.phase：就绪时 attach + refresh；未就绪不发请求。
struct McpSettingsSectionView: View {
    @Environment(McpStore.self) private var mcp
    @Environment(ConnectionStore.self) private var connection

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        List {
            if !isReady {
                Section {
                    Text("settings.mcp.disconnected")
                        .foregroundStyle(.secondary)
                }
            } else if mcp.servers.isEmpty {
                Section {
                    Text("settings.mcp.empty")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(mcp.servers) { server in
                    Section {
                        serverRows(server)
                    } header: {
                        HStack {
                            Text(server.name).font(.headline).textCase(nil)
                            Spacer()
                            authBadge(server.authStatus)
                        }
                    }
                }
            }
        }
        .navigationTitle("settings.mcp")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await mcp.reload() }
                } label: {
                    Label("settings.mcp.reload", systemImage: "arrow.clockwise")
                }
                .disabled(!isReady)
            }
        }
        .task(id: connection.phase) {
            guard isReady, let rpc = connection.rpc else { return }
            await mcp.attach(rpc: rpc)
        }
    }

    // MARK: 行内容

    @ViewBuilder
    private func serverRows(_ server: McpServerStatus) -> some View {
        // 工具：数量 + 名列表
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
        // 资源：数量
        HStack {
            Text("settings.mcp.resources").foregroundStyle(.secondary)
            Spacer()
            Text("\(server.resources.count)").foregroundStyle(.secondary)
        }
    }

    // MARK: 认证徽章

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
