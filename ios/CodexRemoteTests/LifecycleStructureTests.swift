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

    /// D2：ConversationView 退出 / 切 threadId 时停止正文订阅（.task 取消感知 + onDisappear 兜底）。
    func test_conversationView_stopsObservingOnTeardown() throws {
        let src = try source("Views/ConversationView.swift")
        let hits = src.components(separatedBy: "stopObserving").count - 1
        XCTAssertGreaterThanOrEqual(hits, 2,
            "ConversationView 应在 .task 取消路径与 .onDisappear 兜底各调一次 stopObserving（共 ≥2 处）")
        XCTAssertTrue(src.contains(".onDisappear"), "应保留 .onDisappear 兜底停订阅")
    }
}
