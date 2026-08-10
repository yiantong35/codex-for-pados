import SwiftUI

/// 插件详情 sheet（设计 D6 二级/三级下钻）：
/// 打开即 plugin/read 取 PluginDetail → 展示内置 skills（无 skill 则不显示下钻入口）；
/// 点某 skill → plugin/skill/read → 展示正文（NavigationStack 内下钻）。
struct PluginDetailSheet: View {
    @Environment(PluginsStore.self) private var plugins
    @Environment(\.dismiss) private var dismiss

    let plugin: PluginSummary
    let marketplace: String

    @State private var detail: PluginDetail?
    @State private var loadState: ExtensionLoadState = .loading

    var body: some View {
        NavigationStack {
            List {
                if loadState == .loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let detail {
                    if detail.skills.isEmpty {
                        Section {
                            Text("settings.plugins.skills.none").foregroundStyle(.secondary)
                        } header: { Text("settings.plugins.skills") }
                    } else {
                        Section("settings.plugins.skills") {
                            ForEach(dedup(detail.skills)) { skill in
                                NavigationLink {
                                    PluginSkillContentView(
                                        marketplace: marketplace,
                                        pluginId: plugin.effectiveRemotePluginId,
                                        skill: skill)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name).font(.headline)
                                        if !skill.description.isEmpty {
                                            Text(skill.description).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !detail.mcpServers.isEmpty {
                        Section("settings.plugins.mcpServers") {
                            ForEach(detail.mcpServers, id: \.self) { Text($0) }
                        }
                    }
                } else if loadState == .failed {
                    loadError { await loadDetail() }
                }
            }
            .navigationTitle(plugin.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .minimumHitTarget44()
                        .accessibilityLabel(Text("settings.close"))
                }
            }
            .task { await loadDetail() }
        }
    }

    private func loadDetail() async {
        loadState = .loading
        detail = await plugins.readPluginDetail(pluginName: plugin.name, marketplace: marketplace)
        loadState = detail == nil ? .failed : .loaded
    }

    private func loadError(retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(spacing: 10) {
            Label("settings.plugins.detail.failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Button("common.retry") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
                .minimumHitTarget44()
        }
        .frame(maxWidth: .infinity)
    }

    // 按 id（=name）去重，防 SwiftUI ForEach 重复 id 崩溃（与 SkillMetadata 侧对称兜底）。
    private func dedup(_ skills: [SkillSummary]) -> [SkillSummary] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.id).inserted }
    }
}

/// 三级：某内置 skill 的正文（plugin/skill/read → contents）。
struct PluginSkillContentView: View {
    @Environment(PluginsStore.self) private var plugins

    let marketplace: String
    let pluginId: String
    let skill: SkillSummary

    @State private var contents: String?
    @State private var loadState: ExtensionLoadState = .loading

    var body: some View {
        ScrollView {
            if loadState == .loading {
                ProgressView().padding()
            } else if let contents, !contents.isEmpty {
                Text(contents)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            } else if loadState == .loaded {
                Text("settings.plugins.skill.empty").foregroundStyle(.secondary).padding()
            } else {
                VStack(spacing: 10) {
                    Label("settings.plugins.skill.failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("common.retry") { Task { await loadContents() } }
                        .buttonStyle(.borderedProminent)
                        .minimumHitTarget44()
                }
                .padding()
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadContents() }
    }

    private func loadContents() async {
        loadState = .loading
        contents = await plugins.readPluginSkill(
            marketplace: marketplace, pluginId: pluginId, skillName: skill.name)
        loadState = contents == nil ? .failed : .loaded
    }
}
