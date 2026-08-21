import SwiftUI

/// 设置页容器（ipad-settings-page 设计 D1/D2）：左导航 List + 右 detail switch。
/// 以 .sheet 呈现（Task 6 接线 env.attach + gear 触发）。默认选中 .account。
struct SettingsPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(EnvironmentStore.self) private var env
    @Environment(ThemeManager.self) private var theme
    @Environment(TextScaleManager.self) private var textScale
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
        } detail: {
            Group {
                switch selection ?? .default {
                case .account:    AccountSettingsSectionView()
                case .appearance: AppearanceSettingsSectionView()
                case .privacy:    PrivacySettingsSectionView()
                case .language:   LanguageSettingsSectionView()
                case .extensions: ExtensionsSectionView()
                case .shortcuts:  ShortcutsSettingsSectionView()
                }
            }
            .toolbar {
                // The visible detail owns dismissal, so compact column collapse cannot hide it.
                ToolbarItem(placement: .confirmationAction) {
                    closeButton
                }
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
        // 同理：dynamicTypeSize 由 UITraitCollection 背书，sheet 的独立 hosting controller
        // 从系统 trait 重新取值，**不继承**父树施加的 SwiftUI 钳制（对象型环境能穿透，trait 型不能）。
        // 故必须在 sheet 内自读 textScale 再施加——否则设置页看不到字号变化（真机实证）。
        .modifier(AppDynamicTypeSizeModifier(size: textScale.overrideSize))
        // iPad 大屏放大 sheet：默认 form 尺寸在 12.9"/13" iPad 上显得过小（真机实证）。
        .settingsSheetSizing()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .accessibilityLabel(Text("settings.close"))
        }
        .minimumHitTarget44()
        .keyboardShortcut(.cancelAction)
    }
}

/// 设置 sheet 尺寸：iPad 大屏下把默认 form 尺寸放大到 page（更接近全屏，仍保留 sheet 语义）。
/// `presentationSizing` 仅 iOS 18+；iOS 17 回落系统默认（form）尺寸。
private extension View {
    @ViewBuilder func settingsSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}

/// Settings available before pairing. Connection-backed account and extension sections are
/// intentionally omitted; appearance, privacy, language, and keyboard accessibility remain usable.
struct PrePairingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(TextScaleManager.self) private var textScale
    @State private var selection: SettingsSection? = .appearance
    let systemColorScheme: ColorScheme

    private let sections: [SettingsSection] = [.appearance, .privacy, .language, .shortcuts]

    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { section in
                Label(section.label, systemImage: section.icon).tag(section)
            }
            .navigationBarTitleDisplayMode(.inline)
        } detail: {
            Group {
                switch selection ?? .appearance {
                case .appearance: AppearanceSettingsSectionView()
                case .privacy: PrivacySettingsSectionView()
                case .language: LanguageSettingsSectionView()
                case .shortcuts: ShortcutsSettingsSectionView()
                case .account, .extensions: EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    closeButton
                }
            }
        }
        .preferredColorScheme(theme.resolvedColorScheme(system: systemColorScheme))
        // sheet 内自读 textScale 再施加 dynamicTypeSize 钳制（见 SettingsPageView 同处注释）。
        .modifier(AppDynamicTypeSizeModifier(size: textScale.overrideSize))
        // iPad 大屏放大 sheet（见 SettingsPageView 同处注释）。
        .settingsSheetSizing()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .accessibilityLabel(Text("settings.close"))
        }
        .minimumHitTarget44()
        .keyboardShortcut(.cancelAction)
    }
}
