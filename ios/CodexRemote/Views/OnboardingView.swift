import SwiftUI

/// 零机器引导页：居中卡片（图标 + 标题 + 说明 + 主按钮），点「添加第一台机器」
/// 调 `sessions.presentAddMachine()` 打开 MachineFormView sheet（sheet 挂在稳定层，见 CodexRemoteApp）。
/// 无设置齿轮（D13——引导态不给设置入口）。
struct OnboardingView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            GeometryReader { geo in
                ScrollView {
                    card
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .frame(minHeight: geo.size.height)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .minimumHitTarget44()
                .accessibilityLabel(Text("settings.accessibility"))
            }
            .padding(.horizontal, 16)
            .background(.bar)
        }
        .sheet(isPresented: $showSettings) {
            PrePairingSettingsView(systemColorScheme: systemColorScheme)
        }
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("onboarding.title")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("onboarding.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                sessions.presentAddMachine()
            } label: {
                Text("onboarding.addFirst")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }
}
