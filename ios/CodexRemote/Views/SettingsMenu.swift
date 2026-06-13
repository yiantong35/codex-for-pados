import SwiftUI

/// 右上角全局设置菜单（appearance-locale §35）：齿轮按钮展开，含「语言」与「外观」两组。
/// 当前选中项带勾选标识。复用于 ConnectionConfigView 与 RootSplitView 的 toolbar。
/// LocaleManager / ThemeManager 由 App 根注入，这里用 @Environment 读取并修改。
struct SettingsMenu: View {
    @Environment(LocaleManager.self) private var locale
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Menu {
            // 语言
            Section("settings.language") {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Button { locale.language = lang } label: {
                        if locale.language == lang {
                            Label(languageTitle(lang), systemImage: "checkmark")
                        } else {
                            Text(languageTitle(lang))
                        }
                    }
                }
            }
            // 外观
            Section("settings.appearance") {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    Button { theme.theme = t } label: {
                        if theme.theme == t {
                            Label(themeTitle(t), systemImage: "checkmark")
                        } else {
                            Text(themeTitle(t))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .accessibilityLabel(Text("settings.accessibility"))
        }
    }

    private func languageTitle(_ l: AppLanguage) -> LocalizedStringKey {
        switch l {
        case .zh: return "settings.language.zh"
        case .en: return "settings.language.en"
        }
    }

    private func themeTitle(_ t: AppTheme) -> LocalizedStringKey {
        switch t {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
}
