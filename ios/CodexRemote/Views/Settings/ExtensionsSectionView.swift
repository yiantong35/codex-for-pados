import SwiftUI

/// 扩展分区容器（设计 D1）：单 List，三个分组 Section（MCP / Skills / Plugins）。
/// 三 store 各自经 .task(id: connection.phase) attach；一组失败/空不影响其它组（D7）。
struct ExtensionsSectionView: View {
    @Environment(McpStore.self) private var mcp
    @Environment(SkillsStore.self) private var skills
    @Environment(PluginsStore.self) private var plugins
    @Environment(ConnectionStore.self) private var connection

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        List {
            Section("settings.extensions.group.mcp") {
                McpGroupContent()
            }
            Section("settings.extensions.group.skills") {
                SkillsGroupContent()
            }
            Section("settings.extensions.group.plugins") {
                PluginsGroupContent()
            }
        }
        .navigationTitle("settings.extensions")
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
            await skills.attach(rpc: rpc)
            await plugins.attach(rpc: rpc)
        }
    }
}
