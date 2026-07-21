import Testing
import SwiftUI
@testable import CodexRemote

struct SettingsSectionTests {
    @Test func allCasesOrderIsAccountAppearanceLanguageExtensionsShortcuts() {
        #expect(SettingsSection.allCases == [.account, .appearance, .language, .extensions, .shortcuts])
    }

    @Test func shortcutsSectionHasIcon() {
        #expect(SettingsSection.shortcuts.icon == "keyboard")
    }

    @Test func defaultSelectionIsAccount() {
        #expect(SettingsSection.default == .account)
    }

    @Test func eachCaseHasIcon() {
        #expect(SettingsSection.account.icon == "person.crop.circle")
        #expect(SettingsSection.appearance.icon == "paintbrush")
        #expect(SettingsSection.language.icon == "globe")
        #expect(SettingsSection.extensions.icon == "puzzlepiece.extension.fill")
        #expect(SettingsSection.shortcuts.icon == "keyboard")
    }

    @Test func idEqualsSelfForNavigationSelection() {
        for s in SettingsSection.allCases {
            #expect(s.id == s)
        }
    }
}
