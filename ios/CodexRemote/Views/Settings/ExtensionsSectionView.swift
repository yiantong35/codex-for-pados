import SwiftUI

/// 扩展分区容器（设计 D1/D2/D3）：四组自绘可折叠分组（MCP/Skills/Plugins/Hooks）。
/// 折叠头 = 旋转箭头 + 组名 + 计数徽章 + 独立刷新按钮 ↻；折叠态 @AppStorage 跨会话持久化（默认折叠）。
/// 内容 `if isExpanded { GroupContent() }` 条件渲染，复用现有三组内容视图 + 新 HooksGroupContent。
/// 四 store 经 .task(id:) attach（D2：折叠也拉数据以显计数）。刷新双入口：每组 ↻（只刷该组）
/// + 右上「全部刷新」（并发四组）；转圈 loading 由本视图 refreshing 集合驱动（D3）。
struct ExtensionsSectionView: View {
    @Environment(McpStore.self) private var mcp
    @Environment(SkillsStore.self) private var skills
    @Environment(PluginsStore.self) private var plugins
    @Environment(HooksStore.self) private var hooks
    @Environment(ConnectionStore.self) private var connection

    // 折叠态跨会话持久化（默认 false=折叠），key 前缀 ext.group.expanded. 避开现有 key 空间。
    @AppStorage("ext.group.expanded.mcp") private var mcpExpanded = false
    @AppStorage("ext.group.expanded.skills") private var skillsExpanded = false
    @AppStorage("ext.group.expanded.plugins") private var pluginsExpanded = false
    @AppStorage("ext.group.expanded.hooks") private var hooksExpanded = false

    // 每组独立刷新 loading 态（key: mcp/skills/plugins/hooks）。
    @State private var refreshing: Set<String> = []

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        List {
            group(key: "mcp", title: "settings.extensions.group.mcp",
                  count: mcp.count, isExpanded: $mcpExpanded,
                  refresh: { await mcp.reload() }) { McpGroupContent() }
            group(key: "skills", title: "settings.extensions.group.skills",
                  count: skills.count, isExpanded: $skillsExpanded,
                  refresh: { await skills.refresh() }) { SkillsGroupContent() }
            group(key: "plugins", title: "settings.extensions.group.plugins",
                  count: plugins.count, isExpanded: $pluginsExpanded,
                  refresh: { await plugins.refresh() }) { PluginsGroupContent() }
            group(key: "hooks", title: "settings.extensions.group.hooks",
                  count: hooks.count, isExpanded: $hooksExpanded,
                  refresh: { await hooks.refresh() }) { HooksGroupContent() }
        }
        .navigationTitle("settings.extensions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // 并发四组：各自独立 Task，互不阻塞（每组 loading 独立转圈）。
                    runRefresh("mcp") { await mcp.reload() }
                    runRefresh("skills") { await skills.refresh() }
                    runRefresh("plugins") { await plugins.refresh() }
                    runRefresh("hooks") { await hooks.refresh() }
                } label: {
                    Label("settings.extensions.refreshAll", systemImage: "arrow.clockwise")
                }
                .disabled(!isReady)
            }
        }
        .task(id: connection.phase) {
            guard isReady, let rpc = connection.rpc else { return }
            await mcp.attach(rpc: rpc)
            await skills.attach(rpc: rpc)
            await plugins.attach(rpc: rpc)
            await hooks.attach(rpc: rpc)
        }
    }

    // MARK: 自绘折叠分组

    @ViewBuilder
    private func group<Content: View>(
        key: String, title: LocalizedStringKey, count: Int,
        isExpanded: Binding<Bool>, refresh: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            header(key: key, title: title, count: count, isExpanded: isExpanded, refresh: refresh)
            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    // 折叠头：展开区（箭头+组名+计数徽章）与刷新按钮各自独立点击区（D1：手势不冲突）。
    @ViewBuilder
    private func header(
        key: String, title: LocalizedStringKey, count: Int,
        isExpanded: Binding<Bool>, refresh: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title).font(.headline)
                    if isReady { countBadge(count) }   // 未连接不显徽章（D2/D7）
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if refreshing.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                Button { runRefresh(key, refresh) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .minimumHitTarget44()
                .disabled(!isReady)
                .accessibilityLabel("settings.extensions.group.refresh")
            }
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // 置 loading → 跑刷新 → 清 loading（每组独立；全部刷新时并发多个 Task 各自转圈）。
    private func runRefresh(_ key: String, _ op: @escaping () async -> Void) {
        guard isReady else { return }
        refreshing.insert(key)
        Task {
            await op()
            refreshing.remove(key)
        }
    }
}
