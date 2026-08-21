import SwiftUI

/// 语言分区（设计 D6）：读改根注入的 LocaleManager，选择即时生效，当前项带勾选标识。
struct LanguageSettingsSectionView: View {
    @Environment(LocaleManager.self) private var locale

    var body: some View {
        List {
            // 不再重复页面大标题「语言」（navigationTitle 已给出），去掉冗余 section header。
            Section {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Button {
                        locale.language = lang
                    } label: {
                        HStack {
                            Text(title(lang)).foregroundStyle(.primary)
                            Spacer()
                            if locale.language == lang {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .navigationTitle(L10n.string("settings.language", locale: locale.locale))
        .id(locale.locale.identifier)
    }

    private func title(_ l: AppLanguage) -> LocalizedStringKey {
        switch l {
        case .system: return "settings.language.system"
        case .zh: return "settings.language.zh"
        case .en: return "settings.language.en"
        }
    }
}
