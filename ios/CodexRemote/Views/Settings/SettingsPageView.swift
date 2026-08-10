import SwiftUI

/// 设置页容器（ipad-settings-page 设计 D1/D2）：左导航 List + 右 detail switch。
/// 以 .sheet 呈现（Task 6 接线 env.attach + gear 触发）。默认选中 .account。
struct SettingsPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(EnvironmentStore.self) private var env
    @Environment(ThemeManager.self) private var theme
    @State private var selection: SettingsSection? = .default

    /// 由呈现方（宿主）传入的真实系统深浅值。用于把 `.system` 主题解析成具体 ColorScheme，
    /// 规避 sheet 上 `.preferredColorScheme(nil)` 无法重置强制深/浅色的 SwiftUI 行为。
    let systemColorScheme: ColorScheme

    init(systemColorScheme: ColorScheme) {
        self.systemColorScheme = systemColorScheme
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左上角关闭：明确的 X 按钮，符合 iPad sheet 惯例（唯一关闭入口）。
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel(Text("settings.close"))
                    }
                    .keyboardShortcut(.cancelAction)   // T11：Esc 关闭设置
                }
            }
        } detail: {
            switch selection ?? .default {
            case .account:    AccountSettingsSectionView()
            case .appearance: AppearanceSettingsSectionView()
            case .privacy:    PrivacySettingsSectionView()
            case .language:   LanguageSettingsSectionView()
            case .extensions: ExtensionsSectionView()
            case .shortcuts:  ShortcutsSettingsSectionView()
            }
        }
        .task(id: connection.phase) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await env.attach(rpc: rpc)
        }
        // sheet 是独立呈现宿主，不继承父树的 preferredColorScheme——需在 sheet 内自声明。
        // 用 resolvedColorScheme 把 .system 解析成具体值（而非 nil），既能即时切换、
        // 又能从深/浅色正确切回跟随系统（否则 sheet 卡在旧强制值 → 里黑外白）。
        .preferredColorScheme(theme.resolvedColorScheme(system: systemColorScheme))
    }
}

/// Settings available before pairing. Connection-backed account and extension sections are
/// intentionally omitted; appearance, privacy, language, and keyboard accessibility remain usable.
struct PrePairingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @State private var selection: SettingsSection? = .appearance
    let systemColorScheme: ColorScheme

    private let sections: [SettingsSection] = [.appearance, .privacy, .language, .shortcuts]

    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { section in
                Label(section.label, systemImage: section.icon).tag(section)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel(Text("settings.close"))
                    }
                    .minimumHitTarget44()
                    .keyboardShortcut(.cancelAction)
                }
            }
        } detail: {
            switch selection ?? .appearance {
            case .appearance: AppearanceSettingsSectionView()
            case .privacy: PrivacySettingsSectionView()
            case .language: LanguageSettingsSectionView()
            case .shortcuts: ShortcutsSettingsSectionView()
            case .account, .extensions: EmptyView()
            }
        }
        .preferredColorScheme(theme.resolvedColorScheme(system: systemColorScheme))
    }
}
