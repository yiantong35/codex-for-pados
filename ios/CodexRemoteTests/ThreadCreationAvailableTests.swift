import XCTest
@testable import CodexRemote

@MainActor
final class ThreadCreationAvailableTests: XCTestCase {
    /// 反转 follower 的「禁发起」守护：iPad 作为对等客户端，建会话能力必须可用。
    /// 防止「恢复入口」被未来改动悄悄删回从端定位。
    func testSourceHasThreadCreationSymbols() throws {
        let root = URL(fileURLWithPath: #filePath)        // .../ios/CodexRemoteTests/ThreadCreationAvailableTests.swift
            .deletingLastPathComponent()                  // CodexRemoteTests
            .deletingLastPathComponent()                  // ios
        let conv = try String(contentsOf: root.appendingPathComponent("CodexRemote/Stores/ConversationStore.swift"), encoding: .utf8)
        XCTAssertTrue(conv.contains("func start("), "ConversationStore.start() 应已恢复")
        XCTAssertTrue(conv.contains("func fork("), "ConversationStore.fork() 应已新增")
        XCTAssertTrue(conv.contains("threadStart"), "应引用 RPCMethod.threadStart")
        let types = try String(contentsOf: root.appendingPathComponent("CodexRemote/Protocol/ThreadTypes.swift"), encoding: .utf8)
        XCTAssertTrue(types.contains("ThreadStartParams"), "ThreadStartParams 应已恢复")
        XCTAssertTrue(types.contains("ThreadForkParams"), "ThreadForkParams 应已新增")
    }

    /// D1:顶栏游离新建入口(无项目归属、cwd=nil)必须移除。结构性断言——不挂靠 WorkspaceUIRegressionTests
    /// (本分支 2 个 toolbar 渲染测试已知在 test host 不渲染)。
    func testTopBarFloatingNewThreadRemoved() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodexRemoteTests
            .deletingLastPathComponent()   // ios
        let src = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/RootSplitView.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.contains("createThread: createThread"),
                       "WorkspaceToolbar 不应再接顶栏 createThread 闭包")
        XCTAssertFalse(src.contains("projects.createThread(rpc: rpc)"),
                       "nil-cwd 的游离新建调用路径应已移除")
    }

    /// D1/D2:项目行菜单承载「新建会话」并携带该项目 cwd。结构性断言(View 触发逻辑不易单测,
    /// 与 store 帧含 cwd 契约测试 test_createThread_encodes_cwd_in_frame 互补)。
    func testProjectRowNewThreadPassesProjectCwd() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/SidebarView.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("func projectActions"),
                      "项目行应新增 projectActions 菜单承载新建会话")
        XCTAssertTrue(src.contains("cwd: project.cwd"),
                      "项目内新建应携带 project.cwd")
    }
}
