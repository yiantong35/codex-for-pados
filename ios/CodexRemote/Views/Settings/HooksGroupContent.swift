import SwiftUI

/// Hooks 分组内容（设计 D6）：只读平铺展示 hooks/list（eventName 主标题 + handlerType/trustStatus 徽章
/// + 启用态 + matcher/command 副行 + source 尾行）。未连接不发请求（attach 由 ExtensionsSectionView 统一负责）；
/// 空态兜底；未知枚举落 unknown 文案。id = key（跨 cwd 打平时已按 key 去重，见 HooksStore）。
struct HooksGroupContent: View {
    @Environment(HooksStore.self) private var hooks
    @Environment(ConnectionStore.self) private var connection

    private var isReady: Bool { connection.phase == .ready }

    var body: some View {
        if !isReady {
            Text("settings.hooks.disconnected").foregroundStyle(.secondary)
        } else if hooks.hooks.isEmpty {
            Text("settings.hooks.empty").foregroundStyle(.secondary)
        } else {
            ForEach(hooks.hooks) { hook in
                hookRow(hook)
            }
        }
    }

    @ViewBuilder
    private func hookRow(_ hook: HookMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(eventLabel(hook.eventName)).font(.headline)
                    .lineLimit(1)   // 长事件名先截断，保住同行徽章不被挤没（D8 窄屏）
                handlerBadge(hook.handlerType)
                trustBadge(hook.trustStatus)
                Spacer(minLength: 0)
                Text(hook.enabled ? "settings.hooks.enabled" : "settings.hooks.disabled")
                    .font(.caption2)
                    .foregroundStyle(hook.enabled ? .green : .secondary)
            }
            if let matcher = hook.matcher, !matcher.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("settings.hooks.matcher").font(.caption2).foregroundStyle(.secondary)
                    Text(matcher).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)   // glob/正则单行，中部省略（D8 窄屏）
                }
            }
            if let command = hook.command, !command.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("settings.hooks.command").font(.caption2).foregroundStyle(.secondary)
                    Text(command).font(.caption2).monospaced().foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)   // 长命令最多 2 行，中部省略防撑高（D8 窄屏）
                }
            }
            HStack(spacing: 4) {
                Text("settings.hooks.source").font(.caption2).foregroundStyle(.tertiary)
                Text(sourceLabel(hook.source)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 徽章

    private func handlerBadge(_ t: HookHandlerType) -> some View {
        Text(handlerLabel(t))
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func trustBadge(_ s: HookTrustStatus) -> some View {
        Text(trustLabel(s))
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(trustColor(s).opacity(0.15), in: Capsule())
            .foregroundStyle(trustColor(s))
    }

    private func trustColor(_ s: HookTrustStatus) -> Color {
        switch s {
        case .trusted:   return .green
        case .untrusted: return .orange
        case .modified:  return .yellow
        case .managed:   return .secondary
        case .unknown:   return .secondary
        }
    }

    // MARK: 文案映射（未知枚举兜底）

    private func eventLabel(_ e: HookEventName) -> LocalizedStringKey {
        switch e {
        case .preToolUse:       return "settings.hooks.event.preToolUse"
        case .permissionRequest:return "settings.hooks.event.permissionRequest"
        case .postToolUse:      return "settings.hooks.event.postToolUse"
        case .preCompact:       return "settings.hooks.event.preCompact"
        case .postCompact:      return "settings.hooks.event.postCompact"
        case .sessionStart:     return "settings.hooks.event.sessionStart"
        case .userPromptSubmit: return "settings.hooks.event.userPromptSubmit"
        case .subagentStart:    return "settings.hooks.event.subagentStart"
        case .subagentStop:     return "settings.hooks.event.subagentStop"
        case .stop:             return "settings.hooks.event.stop"
        case .unknown:          return "settings.hooks.event.unknown"
        }
    }

    private func handlerLabel(_ t: HookHandlerType) -> LocalizedStringKey {
        switch t {
        case .command: return "settings.hooks.handler.command"
        case .prompt:  return "settings.hooks.handler.prompt"
        case .agent:   return "settings.hooks.handler.agent"
        case .unknown: return "settings.hooks.handler.unknown"
        }
    }

    private func trustLabel(_ s: HookTrustStatus) -> LocalizedStringKey {
        switch s {
        case .managed:   return "settings.hooks.trust.managed"
        case .untrusted: return "settings.hooks.trust.untrusted"
        case .trusted:   return "settings.hooks.trust.trusted"
        case .modified:  return "settings.hooks.trust.modified"
        case .unknown:   return "settings.hooks.trust.unknown"
        }
    }

    private func sourceLabel(_ s: HookSource) -> LocalizedStringKey {
        switch s {
        case .system:                 return "settings.hooks.src.system"
        case .user:                   return "settings.hooks.src.user"
        case .project:                return "settings.hooks.src.project"
        case .mdm:                    return "settings.hooks.src.mdm"
        case .sessionFlags:           return "settings.hooks.src.sessionFlags"
        case .plugin:                 return "settings.hooks.src.plugin"
        case .cloudRequirements:      return "settings.hooks.src.cloudRequirements"
        case .cloudManagedConfig:     return "settings.hooks.src.cloudManagedConfig"
        case .legacyManagedConfigFile:return "settings.hooks.src.legacyManagedConfigFile"
        case .legacyManagedConfigMdm: return "settings.hooks.src.legacyManagedConfigMdm"
        case .unknown:                return "settings.hooks.src.unknown"
        }
    }
}
