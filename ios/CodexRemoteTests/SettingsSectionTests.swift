import Testing
import SwiftUI
@testable import CodexRemote

struct SettingsSectionTests {
    @Test func allCasesOrderIsAccountAppearanceLanguageMcp() {
        #expect(SettingsSection.allCases == [.account, .appearance, .language, .mcp])
    }

    @Test func defaultSelectionIsAccount() {
        #expect(SettingsSection.default == .account)
    }

    @Test func eachCaseHasIcon() {
        #expect(SettingsSection.account.icon == "person.crop.circle")
        #expect(SettingsSection.appearance.icon == "paintbrush")
        #expect(SettingsSection.language.icon == "globe")
        #expect(SettingsSection.mcp.icon == "puzzlepiece.extension")
    }

    @Test func idEqualsSelfForNavigationSelection() {
        for s in SettingsSection.allCases {
            #expect(s.id == s)
        }
    }
}
