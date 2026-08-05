import SwiftUI

/// Skills 分组内容（设计 D4/D7）：只读列表 + 启用开关 + scope 徽章 + 依赖工具展示。
/// 未连接不发请求（attach 由 ExtensionsSectionView 统一负责）；空态/未知 scope 兜底。
struct SkillsGroupContent: View {
    @Environment(SkillsStore.self) private var skills
    @Environment(ConnectionStore.self) private var connection

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        if !isReady {
            Text("settings.skills.disconnected").foregroundStyle(.secondary)
        } else if skills.skills.isEmpty {
            Text("settings.skills.empty").foregroundStyle(.secondary)
        } else {
            ForEach(skills.skills) { skill in
                skillRow(skill)
            }
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.name).font(.headline)
                scopeBadge(skill.scope)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { newValue in
                        Task { await skills.setEnabled(name: nil, path: skill.path, newValue) }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(Text(skill.name))
            }
            if !skill.description.isEmpty {
                Text(skill.description).font(.footnote).foregroundStyle(.secondary)
            }
            if let tools = skill.dependencies?.tools, !tools.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("settings.skills.dependencies").font(.caption2).foregroundStyle(.secondary)
                    Text(tools.map { $0.value }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // scope 徽章（未知 scope 兜底为「未知」文案）。
    private func scopeBadge(_ scope: SkillScope) -> some View {
        Text(scopeLabel(scope))
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func scopeLabel(_ scope: SkillScope) -> LocalizedStringKey {
        switch scope {
        case .user:    return "settings.skills.scope.user"
        case .repo:    return "settings.skills.scope.repo"
        case .system:  return "settings.skills.scope.system"
        case .admin:   return "settings.skills.scope.admin"
        case .unknown: return "settings.skills.scope.unknown"
        }
    }
}
