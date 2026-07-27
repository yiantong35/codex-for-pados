import XCTest
@testable import CodexRemote

final class LifecycleStructureTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexRemote")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_appForegroundBroadcast_livesInRootViewNotWorkspaceHost() throws {
        let src = try source("App/CodexRemoteApp.swift")
        XCTAssertTrue(src.contains("setAppForegroundAll"),
                      "RootView 应经 sessions.setAppForegroundAll 广播 app 级前后台")
        XCTAssertFalse(src.contains("connection.setForeground(phase == .active)"),
                       "WorkspaceHost 不得再自持 scenePhase→connection.setForeground 转发")
    }

    /// D2：ConversationView 退出 / 切 threadId 时停止正文订阅。
    /// 注：SwiftUI 的 .task 取消 / onDisappear 在无头环境无法运行时验证，此处为结构级回归守卫
    /// （非行为测试）——行为由 ConversationStoreTests 的订阅数恒 1 覆盖。
    func test_conversationView_stopsObservingOnTeardown() throws {
        let src = try source("Views/ConversationView.swift")
        let calls = src.components(separatedBy: "stopObserving()").count - 1
        XCTAssertGreaterThanOrEqual(calls, 2,
            "ConversationView 应在 .task 取消路径（defer）与 .onDisappear 兜底各调一次 stopObserving()")
        XCTAssertTrue(src.contains(".onDisappear"), "应保留 .onDisappear 兜底停订阅")
        XCTAssertTrue(src.contains("defer { s.stopObserving() }") || src.contains("defer {s.stopObserving()}"),
            ".task 应用 defer 绑定订阅生命周期")
    }
}
