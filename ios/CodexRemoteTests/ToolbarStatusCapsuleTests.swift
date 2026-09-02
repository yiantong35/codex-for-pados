import XCTest
import SwiftUI
@testable import CodexRemote

/// toolbar-status-and-jump-to-latest Task 1：状态胶囊四态映射纯函数 + holder 新字段生命周期。
/// 断言集中 holder 状态层与纯函数层，不硬测 toolbar 无障碍树（BACKLOG line89 宿主脆弱性在案）；
/// toolbar 声明用源码级结构断言（对齐 WorkspaceUIRegressionTests 范式）。
@MainActor
final class ToolbarStatusCapsuleTests: XCTestCase {

    // MARK: 四态映射（沿用旧自挂 ToolbarItem 语义：优先级 loading > failed > running > idle）

    func test_descriptor_loading() {
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .loading, isTurnRunning: false),
            .init(key: "conv.loading", symbol: "arrow.clockwise", tint: .secondary))
    }
    func test_descriptor_failed_beatsRunning() {
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .failed, isTurnRunning: true),
            .init(key: "conv.loadFailed", symbol: "exclamationmark.triangle.fill", tint: .red))
    }
    func test_descriptor_loading_beatsRunning() {
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .loading, isTurnRunning: true)?.key,
            "conv.loading")
    }
    func test_descriptor_runningAndIdle() {
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .loaded, isTurnRunning: true),
            .init(key: "conv.running", symbol: "circle.fill", tint: .orange))
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .loaded, isTurnRunning: false),
            .init(key: "conv.idle", symbol: "checkmark.circle", tint: .secondary))
        XCTAssertEqual(
            ConversationStatusPresentation.descriptor(loadState: .idle, isTurnRunning: false)?.key,
            "conv.idle")
    }
    func test_descriptor_nilLoadState_hidesWholeBlock() {
        XCTAssertNil(ConversationStatusPresentation.descriptor(loadState: nil, isTurnRunning: false))
        XCTAssertNil(ConversationStatusPresentation.descriptor(loadState: nil, isTurnRunning: true),
                     "无会话时即使残留 running 也整块隐藏（spec：无会话选中时隐藏）")
    }

    // MARK: holder 新字段默认值与统一清理

    func test_holder_newFieldsDefaultEmpty() {
        let holder = ActiveConversationHolder()
        XCTAssertNil(holder.loadState)
        XCTAssertFalse(holder.isTurnRunning)
        XCTAssertNil(holder.refresh)
    }

    func test_clearConversationBinding_resetsAllFields() {
        let holder = ActiveConversationHolder()
        holder.state = WorkspaceSummary.Snapshot(state: ConversationState(threadId: "t"))
        holder.contextIdentity = "t|rpc"
        holder.loadState = .loaded
        holder.isTurnRunning = true
        holder.refresh = { }
        holder.fetchFullDiff = { _ in nil }
        holder.startReview = { _ in true }
        holder.applyThreadSnapshot = { _, _ in }
        let gen = holder.fetchGeneration
        holder.clearConversationBinding()
        XCTAssertNil(holder.state)
        XCTAssertNil(holder.contextIdentity)
        XCTAssertNil(holder.loadState)
        XCTAssertFalse(holder.isTurnRunning)
        XCTAssertNil(holder.refresh)
        XCTAssertNil(holder.fetchFullDiff)
        XCTAssertNil(holder.startReview)
        XCTAssertNil(holder.applyThreadSnapshot)
        XCTAssertEqual(holder.fetchGeneration, gen &+ 1, "清理须 bump fetchGeneration 令 Full Diff 缓存失效")
    }

    // MARK: 结构断言（源码级：声明顺序契约 + 自挂移除）

    func test_workspaceToolbar_declaresCapsuleBeforeControlGroup() throws {
        let src = try sourceOf("CodexRemote/Views/RootSplitView.swift")
        let capsule = try XCTUnwrap(src.range(of: "ConversationStatusPresentation.descriptor"),
                                    "WorkspaceToolbar 应声明状态胶囊（读取四态映射）")
        let group = try XCTUnwrap(src.range(of: "ControlGroup"))
        XCTAssertTrue(capsule.lowerBound < group.lowerBound,
                      "状态胶囊 ToolbarItem 必须声明在 4 图标 ControlGroup 之前（同 ToolbarContent 内顺序契约）")
    }

    func test_conversationView_noLongerSelfMountsStatusToolbarItem() throws {
        let src = try sourceOf("CodexRemote/Views/ConversationView.swift")
        XCTAssertFalse(src.contains("ToolbarItem(placement: .topBarTrailing)"),
                       "ConversationView 不得再自挂状态 ToolbarItem（改由 WorkspaceToolbar 承载）")
    }

    // MARK: 刷新按钮（Task 2）：loading 禁用防抖 + refresh 注入即 resume

    func test_shouldDisableRefresh_onlyWhileLoading() {
        XCTAssertTrue(ConversationStatusPresentation.shouldDisableRefresh(loadState: .loading))
        XCTAssertFalse(ConversationStatusPresentation.shouldDisableRefresh(loadState: .failed))
        XCTAssertFalse(ConversationStatusPresentation.shouldDisableRefresh(loadState: .loaded))
        XCTAssertFalse(ConversationStatusPresentation.shouldDisableRefresh(loadState: .idle))
        XCTAssertFalse(ConversationStatusPresentation.shouldDisableRefresh(loadState: nil))
    }

    /// 主对话挂载后 holder.refresh 非空，调用即发 thread/resume（spec：正常态手动刷新）。
    func test_mainConversation_injectsRefresh_thatResumes() async throws {
        let transport = MockTransport()
        await transport.setAutoRespond(true)
        await transport.setThreadResumeResponse(#"{"thread":{"id":"refresh-test","turns":[]}}"#)
        let rpc = JSONRPCClient(transport: transport)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "refresh-test")
        let holder = ActiveConversationHolder()
        let view = ConversationView(threadId: "refresh-test", providedStore: store)
            .environment(holder)
            .environment(ApprovalStore())
            .environment(UserInputStore())
            .environment(McpElicitationStore())
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
            .environment(ConnectionStore(transportFactory: { _ in MockTransport() }))
        let window = mount(view, size: CGSize(width: 800, height: 600))
        defer { unmount(window) }
        try await waitUntil { holder.refresh != nil }   // .task 注入完成
        XCTAssertEqual(holder.loadState, store.loadState, "loadState 应桥接进 holder")
        let sentBefore = await transport.sent.count
        await holder.refresh?()
        let resumeSent = await transport.sent.dropFirst(sentBefore)
            .contains { $0.contains(RPCMethod.threadResume) }
        XCTAssertTrue(resumeSent, "refresh 即对当前会话重新发起 resume")
    }

    /// resume 失败保持 failed 可再重试，重试成功转正常态（spec：加载失败态就近重试）。
    /// store 层锁定语义——刷新按钮唯一动作就是 store.resume()。
    func test_refreshAfterFailure_retriesAndRecovers() async throws {
        let transport = MockTransport()
        await transport.setAutoRespond(true)
        await transport.setThreadResumeResponse(#"{"thread":{"id":"retry-test","turns":[]}}"#)
        let rpc = JSONRPCClient(transport: transport)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "retry-test")
        await transport.failNextSend(with: .channelClosed(reason: "scripted"))
        await store.resume()
        XCTAssertEqual(store.loadState, .failed, "resume 失败保持 failed（可再次重试）")
        await store.resume()
        XCTAssertEqual(store.loadState, .loaded, "重试成功转正常态")
    }

    // MARK: 挂载 helper（范式对齐 WorkspaceUIRegressionTests.swift）

    private func mount(_ view: some View, size: CGSize) -> UIWindow {
        let hc = UIHostingController(rootView: AnyView(view))
        hc.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        drainRunLoop()
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func drainRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            drainRunLoop()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("waitUntil 超时：条件未满足")
    }

    private func sourceOf(_ relPath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodexRemoteTests
            .deletingLastPathComponent()   // ios
        return try String(contentsOf: root.appendingPathComponent(relPath), encoding: .utf8)
    }
}
