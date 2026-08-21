import SwiftUI

/// 外观分区（设计 D6）：读改根注入的 ThemeManager，选择即时生效，当前项带勾选标识。
struct AppearanceSettingsSectionView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(TextScaleManager.self) private var textScale
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section("settings.appearance") {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    Button {
                        theme.theme = t
                    } label: {
                        HStack {
                            Text(title(t)).foregroundStyle(.primary)
                            Spacer()
                            if theme.theme == t {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            Section("settings.textSize") {
                ForEach(AppTextScale.allCases) { s in
                    Button {
                        textScale.scale = s
                    } label: {
                        HStack {
                            // 用 L10n 显式查表（跟随注入 locale）。不可写
                            // `Text(LocalizedStringKey("settings.textSize.\(s.rawValue)"))`：运行时插值构造的
                            // LocalizedStringKey 会把插值段当 `%@`、查不到表而回退显示原始 key（真机实证）。
                            Text(verbatim: L10n.string("settings.textSize.\(s.rawValue)", locale: locale))
                                .foregroundStyle(.primary)
                            Spacer()
                            if textScale.scale == s {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(textScale.scale == s ? .isSelected : [])
                }
            }
        }
        .navigationTitle("settings.appearance")
    }

    private func title(_ t: AppTheme) -> LocalizedStringKey {
        switch t {
        case .system: return "settings.appearance.system"
        case .light:  return "settings.appearance.light"
        case .dark:   return "settings.appearance.dark"
        }
    }
}
