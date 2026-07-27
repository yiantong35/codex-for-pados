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
}
