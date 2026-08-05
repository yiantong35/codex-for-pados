import Foundation

/// D5：跟随注入 locale 的本地化查表入口。
/// 关键：不用 `String(localized:)`——它按系统语言选表、忽略应用内注入 locale（LocaleManager）。
/// 复用 ShortcutsSettingsSectionView 已验证的三级 fallback：identifier lproj → 语言码 lproj → 主 bundle。
enum L10n {
    static func string(_ key: String, locale: Locale) -> String {
        if let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        if let code = locale.language.languageCode?.identifier,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
