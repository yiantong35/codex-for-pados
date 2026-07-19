import SwiftUI

/// 零机器引导页：居中卡片（图标 + 标题 + 说明 + 主按钮），点「添加第一台机器」
/// 调 `sessions.presentAddMachine()` 打开 MachineFormView sheet（sheet 挂在稳定层，见 CodexRemoteApp）。
/// 无设置齿轮（D13——引导态不给设置入口）。
struct OnboardingView: View {
    @Environment(SessionsManager.self) private var sessions

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
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("onboarding.title")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("onboarding.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                sessions.presentAddMachine()
            } label: {
                Text("onboarding.addFirst")
                    .frame(maxWidth: .infinity)
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
