import SwiftUI

@main
struct CodexRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            // ⚠️ SPIKE（Task 3）：临时把根视图换成 SpikeView 验证 Citadel exec 握手。
            // 后续任务恢复正式根视图。
            SpikeView()
        }
    }
}
