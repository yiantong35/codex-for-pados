import SwiftUI

/// 右上角全局设置菜单（appearance-locale §35）：齿轮按钮展开，含「语言」与「外观」两组。
/// 当前选中项带勾选标识。复用于 ConnectionConfigView 与 RootSplitView 的 toolbar。
/// LocaleManager / ThemeManager 由 App 根注入，这里用 @Environment 读取并修改。
struct SettingsMenu: View {
    @Environment(LocaleManager.self) private var locale
    @Environment(ThemeManager.self) private var theme
    @State private var showPopover = false

    var body: some View {
        // 用 .popover 而非 Menu：popover 带箭头指向按钮、不遮挡按钮本身（#8）；
        // presentationCompactAdaptation(.popover) 保证窄屏也走 popover 形态而非占满屏 sheet。
        Button { showPopover.toggle() } label: {
            Image(systemName: "gearshape")
                .accessibilityLabel(Text("settings.accessibility"))
        }
        .popover(isPresented: $showPopover) {
            settingsList
                .presentationCompactAdaptation(.popover)
        }
    }

    private var settingsList: some View {
        List {
            Section("settings.language") {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Button { locale.language = lang; showPopover = false } label: {
                        row(languageTitle(lang), selected: locale.language == lang)
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section("settings.appearance") {
                ForEach(AppTheme.allCases, id: \.self) { t in
                    Button { theme.theme = t; showPopover = false } label: {
                        row(themeTitle(t), selected: theme.theme == t)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(width: 260, height: 300)
    }

    private func row(_ title: LocalizedStringKey, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
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
