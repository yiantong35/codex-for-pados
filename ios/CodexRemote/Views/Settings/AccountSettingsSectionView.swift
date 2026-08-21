import SwiftUI

/// 账户分区（设计 D4）：只读展示共享 EnvironmentStore 的账户/用量/限额。
/// env.attach(rpc:) 的就绪 guard 在容器 SettingsPageView（Task 6）统一挂载；
/// 本视图只读渲染当前 store 状态，nil/未就绪 → 空态。
struct AccountSettingsSectionView: View {
    @Environment(EnvironmentStore.self) private var env

    var body: some View {
        List {
            // 不再重复页面大标题「账户」（navigationTitle 已给出），去掉冗余 section header。
            Section {
                AccountInfoView(account: env.account,
                                usage: env.usage,
                                rateLimits: env.rateLimits)
            }
        }
        .navigationTitle("settings.account")
    }
}
