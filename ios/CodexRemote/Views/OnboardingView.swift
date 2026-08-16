import SwiftUI

/// 零机器引导页：使用系统 ContentUnavailableView 呈现单一配对入口。
/// 调 `sessions.presentAddMachine()` 打开 MachineFormView sheet（sheet 挂在稳定层，见 CodexRemoteApp）。
/// 无设置齿轮（D13——引导态不给设置入口）。
struct OnboardingView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("onboarding.title", systemImage: "ipad")
            } description: {
                Text("onboarding.subtitle")
            } actions: {
                Button("onboarding.addFirst") {
                    sessions.presentAddMachine()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("settings.accessibility"))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            PrePairingSettingsView(systemColorScheme: systemColorScheme)
        }
    }

}
