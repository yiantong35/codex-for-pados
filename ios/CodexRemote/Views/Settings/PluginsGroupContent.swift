import SwiftUI

/// Plugins 分组内容（设计 D6/D7）：按 marketplace 分组只读展示插件（名字/分类/启用态/描述）+ 下钻入口。
/// 点插件 → sheet 展示 PluginDetail（内置 skills）→ 点 skill → 读正文。
struct PluginsGroupContent: View {
    @Environment(PluginsStore.self) private var plugins
    @Environment(ConnectionStore.self) private var connection

    @State private var selected: PluginSummary?
    @State private var selectedMarketplace: String = ""

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        Group {
            if !isReady {
                Text("settings.plugins.disconnected").foregroundStyle(.secondary)
            } else if plugins.marketplaces.allSatisfy({ $0.plugins.isEmpty }) {
                Text("settings.plugins.empty").foregroundStyle(.secondary)
            } else {
                ForEach(plugins.marketplaces) { entry in
                    if !entry.plugins.isEmpty {
                        Text(entry.name).font(.caption).foregroundStyle(.secondary)
                        ForEach(dedup(entry.plugins)) { plugin in
                            pluginRow(plugin, marketplace: entry.name)
                        }
                    }
                }
            }
        }
        .sheet(item: $selected) { plugin in
            PluginDetailSheet(plugin: plugin, marketplace: selectedMarketplace)
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: PluginSummary, marketplace: String) -> some View {        Button {
            selectedMarketplace = marketplace
            selected = plugin
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plugin.name).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text(plugin.enabled ? "settings.plugins.enabled" : "settings.plugins.disabled")
                        .font(.caption2)
                        .foregroundStyle(plugin.enabled ? .green : .secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if let category = plugin.category {
                    Text(category).font(.caption).foregroundStyle(.secondary)
                }
                if let desc = plugin.displayDescription, !desc.isEmpty {
                    Text(desc).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // 按 id 去重，防 SwiftUI ForEach 重复 id 崩溃（与 SkillMetadata 侧对称兜底）。
    private func dedup(_ plugins: [PluginSummary]) -> [PluginSummary] {
        var seen = Set<String>()
        return plugins.filter { seen.insert($0.id).inserted }
    }
}
