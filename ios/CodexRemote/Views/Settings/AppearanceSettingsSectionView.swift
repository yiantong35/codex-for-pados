import SwiftUI

/// 外观分区（设计 D6）：读改根注入的 ThemeManager，选择即时生效，当前项带勾选标识。
struct AppearanceSettingsSectionView: View {
    @Environment(ThemeManager.self) private var theme

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
