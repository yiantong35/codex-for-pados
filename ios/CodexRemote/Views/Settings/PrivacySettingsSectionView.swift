import SwiftUI

/// 隐私分区（#1）：远端终端写系统剪贴板门控。默认关闭。
struct PrivacySettingsSectionView: View {
    @Environment(ClipboardPolicyStore.self) private var clipboard

    var body: some View {
        @Bindable var clipboard = clipboard
        List {
            Section {
                Toggle("settings.privacy.allowRemoteClipboardWrite", isOn: $clipboard.allowRemoteWrite)
            } header: {
                Text("settings.privacy.clipboard")
            } footer: {
                Text("settings.privacy.allowRemoteClipboardWrite.footer")
            }
        }
        .navigationTitle("settings.privacy")
    }
}
