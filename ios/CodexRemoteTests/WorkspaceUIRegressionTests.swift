import XCTest
import SwiftUI
import UIKit
@testable import CodexRemote

@MainActor
final class WorkspaceUIRegressionTests: XCTestCase {
    /// 结构性断言:无头 XCTest host 不构建 UINavigationBar,`.toolbar` 内容不入无障碍树
    /// (功能已在模拟器实测正常,见 2026-08-25 验证报告)。改为核验 WorkspaceToolbar 源码定义了
    /// 全部工具栏标签与 settings 触发动作,防被未来改动误删。
    func test_workspaceToolbar_exposesLabelsAndActionsInsideNavigationStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodexRemoteTests
            .deletingLastPathComponent()   // ios
        let src = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/RootSplitView.swift"),
            encoding: .utf8)
        for label in [
            "workspace.leftPanel.toggle", "workspace.bottomPanel.toggle",
            "workspace.summary.toggle", "workspace.rightPanel.toggle",
            "settings.accessibility"
        ] {
            XCTAssertTrue(src.contains(label), "WorkspaceToolbar 应定义工具栏标签 \(label)")
        }
        XCTAssertTrue(src.contains("layout.showSettings = true"),
                      "settings 工具栏按钮应触发 layout.showSettings")

        let tabBar = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/TabBarView.swift"),
            encoding: .utf8)
        XCTAssertTrue(tabBar.contains("tab.machine.switcher"),
                      "机器切换器应挂无障碍标签 tab.machine.switcher")
    }

    /// 结构性断言(理由同上):核验 RootSplitView.body 无条件 `.toolbar` 安装 WorkspaceToolbar,
    /// 且工具栏含机器切换器 TabBarView。
    func test_rootSplitView_runtimeInstallsWorkspaceToolbar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("CodexRemote/Views/RootSplitView.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains(".toolbar {"), "RootSplitView.body 应安装 .toolbar")
        XCTAssertTrue(src.contains("WorkspaceToolbar("), "工具栏应由 WorkspaceToolbar 承载")
        XCTAssertTrue(src.contains("TabBarView()"), "WorkspaceToolbar 应含机器切换器 TabBarView")
    }

    func test_tabBarLongNameRemainsBoundedBesideNarrowToolbarAction() {
        let sessions = makeSessions(machineName: "开发机器-一个足够长且包含中文的工作站名称-0123456789")
        let frames = ToolbarFrameRecorder()
        let view = HStack(spacing: 8) {
            TabBarView()
                .background(FrameReporter { frames.machine = $0 })
            Spacer(minLength: 0)
            Button {} label: { Image(systemName: "gearshape") }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Adjacent action")
                .background(FrameReporter { frames.adjacent = $0 })
        }
        .padding(.horizontal, 8)
        .environment(sessions)

        let window = mount(view, size: CGSize(width: 320, height: 64))
        defer { unmount(window) }
        guard let machineFrame = frames.machine, let adjacentFrame = frames.adjacent else {
            return XCTFail("Narrow toolbar controls were not rendered")
        }
        XCTAssertGreaterThanOrEqual(machineFrame.width, 44)
        XCTAssertGreaterThanOrEqual(machineFrame.height, 44)
        XCTAssertGreaterThanOrEqual(adjacentFrame.width, 44)
        XCTAssertFalse(machineFrame.intersects(adjacentFrame),
                       "Long machine names must truncate before adjacent actions")
    }

    func test_resizableDivider_adjustableFramesAreActually44PointsWide() {
        let view = ResizableColumns(
            leftWidth: .constant(220),
            rightWidth: .constant(280),
            leftVisible: true,
            rightVisible: true,
            lastRequested: .none,
            onResizeEnded: {},
            onDismissOverlay: { _ in }
        ) {
            Color.red
        } center: {
            Color.green
        } right: {
            Color.blue
        }

        let window = mount(view, size: CGSize(width: 834, height: 600))
        defer { unmount(window) }
        let handles = descendants(of: window).compactMap {
            $0 as? AccessibilityAdjustableElement.AdjustableView
        }
        XCTAssertEqual(handles.count, 2)
        for handle in handles {
            let frame = handle.convert(handle.bounds, to: window)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(handle.accessibilityTraits.contains(.adjustable))
            XCTAssertFalse(handle.accessibilityLabel?.isEmpty ?? true)
        }
    }

    /// Enter 发送（narrow-right-panel-and-enter-send）：用户按键路径（UIKit 经 shouldChangeTextIn
    /// 委托询问）的裸 Return 触发发送且不插换行。取代旧「裸 Return=换行不发送」行为锁——
    /// 注：程序化 `insertText` 绕过 shouldChangeTextIn（UIKit 语义），故本测试直接驱动委托方法，
    /// 与 UIKit 对用户 Return（软键盘点击/硬件无修饰按键）的真实询问路径一致。
    func test_composerPlainReturnSendsWithoutInsertingNewline() async throws {
        let transport = MockTransport()
        let rpc = JSONRPCClient(transport: transport)
        await transport.setAutoRespond(true)
        await rpc.start()
        let draft = ComposerDraft()
        draft.text = "first"
        let store = ConversationStore(rpc: rpc, threadId: "return-send-test")
        await store.startObserving()
        let view = ComposerView(store: store, draft: draft)
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
        let window = mount(view, size: CGSize(width: 600, height: 180))
        defer { unmount(window) }

        guard let tv = descendants(of: window).compactMap({ $0 as? UITextView }).first else {
            return XCTFail("Composer must render the UITextView-backed editor")
        }
        _ = tv.becomeFirstResponder()
        drainRunLoop()
        XCTAssertEqual(tv.text, "first", "binding 应已同步进 UITextView")

        // 用户按裸 Return：UIKit 先问 shouldChangeTextIn(替换文本 "\n")——必须被消费（不插换行）并触发发送。
        let allowed = tv.delegate?.textView?(
            tv, shouldChangeTextIn: NSRange(location: tv.text.count, length: 0), replacementText: "\n")
        XCTAssertEqual(allowed, false, "裸 Return 必须被消费,不得插入换行")
        try await waitUntil { await transport.sent.contains { $0.contains("turn/start") } }
        XCTAssertFalse(draft.text.hasSuffix("\n"), "发送路径不得残留触发换行")
    }

    /// review C2 回归锁：Coordinator 每轮 updateUIView 刷新 parent——isEnabled 由 false 翻 true 后
    /// （真实挂载路径 loading→loaded），裸 Return 仍能发送（陈旧捕获会令闭包永持 isEnabled=false,
    /// Return 被吞死且永不发送）。
    func test_composerReturnSendsAfterEnabledFlip() async throws {
        let transport = MockTransport()
        let rpc = JSONRPCClient(transport: transport)
        await transport.setAutoRespond(true)
        await rpc.start()
        let draft = ComposerDraft()
        draft.text = "after-flip"
        let store = ConversationStore(rpc: rpc, threadId: "enabled-flip-test")
        await store.startObserving()
        let holder = ComposerEnabledFlipHolder()
        let window = mount(ComposerEnabledFlipHost(holder: holder, store: store, draft: draft),
                           size: CGSize(width: 600, height: 180))
        defer { unmount(window) }

        holder.enabled = true            // loading → loaded
        drainRunLoop()
        guard let tv = descendants(of: window).compactMap({ $0 as? UITextView }).first else {
            return XCTFail("Composer must render the UITextView-backed editor")
        }
        _ = tv.becomeFirstResponder()
        drainRunLoop()
        XCTAssertTrue(tv.isEditable, "isEnabled 翻 true 后应可编辑（.disabled 桥接传播）")
        let allowed = tv.delegate?.textView?(
            tv, shouldChangeTextIn: NSRange(location: tv.text.count, length: 0), replacementText: "\n")
        XCTAssertEqual(allowed, false)
        try await waitUntil { await transport.sent.contains { $0.contains("turn/start") } }
    }

    /// 多行粘贴（replacement ≠ "\n"）不拦截不误发；IME 组合态语义由
    /// ComposerSendInteractionTests.test_interceptDecision_markedText_passesThroughForIME 纯函数锁定。
    func test_composerMultilinePasteDoesNotSend() async throws {
        let transport = MockTransport()
        let rpc = JSONRPCClient(transport: transport)
        await transport.setAutoRespond(true)
        await rpc.start()
        let draft = ComposerDraft()
        let store = ConversationStore(rpc: rpc, threadId: "paste-test")
        let view = ComposerView(store: store, draft: draft)
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
        let window = mount(view, size: CGSize(width: 600, height: 180))
        defer { unmount(window) }

        guard let tv = descendants(of: window).compactMap({ $0 as? UITextView }).first else {
            return XCTFail("Composer must render the UITextView-backed editor")
        }
        _ = tv.becomeFirstResponder()
        drainRunLoop()
        let allowed = tv.delegate?.textView?(
            tv, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "line1\nline2")
        XCTAssertEqual(allowed, true, "多行粘贴必须放行插入")
        try await Task.sleep(for: .milliseconds(120))
        let sent = await transport.sent
        XCTAssertFalse(sent.contains { $0.contains("turn/start") }, "多行粘贴不得触发发送")
    }

    func test_composerCommandReturnSends() async throws {
        let transport = MockTransport()
        let rpc = JSONRPCClient(transport: transport)
        await transport.setAutoRespond(true)
        await rpc.start()
        let draft = ComposerDraft()
        draft.text = "send with command return"
        let store = ConversationStore(rpc: rpc, threadId: "command-return-test")
        await store.startObserving()
        let view = ComposerView(store: store, draft: draft)
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
        let window = mount(view, size: CGSize(width: 600, height: 180))
        defer { unmount(window) }
        guard let responder = descendants(of: window).first(where: { $0 is UITextField || $0 is UITextView }) else {
            return XCTFail("Composer must render a native text input")
        }
        _ = responder.becomeFirstResponder()
        drainRunLoop()

        let command = commandReturn(in: responderChain(from: responder))
        XCTAssertNotNil(command, "Composer must register Cmd+Return as a real key command")

        await ComposerView.executeSendShortcut(
            isEnabled: true,
            canSend: true,
            isTurnRunning: false,
            send: { await store.send(input: [.text(draft.text)], model: nil, effort: nil) },
            enqueue: {}
        )
        try await waitUntil { await transport.sent.contains { $0.contains("turn/start") } }
    }

    func test_workspaceEmptyState_actionDoesNotShiftPrimaryContent() {
        let withoutAction = renderedImage(
            WorkspaceEmptyState(title: "sidebar.empty.title",
                                description: "sidebar.empty.desc", systemImage: "tray"),
            size: CGSize(width: 280, height: 500)
        )
        let withAction = renderedImage(
            WorkspaceEmptyState(title: "sidebar.empty.title", description: "sidebar.empty.desc",
                                systemImage: "tray", actionTitle: "sidebar.retry", action: {}),
            size: CGSize(width: 280, height: 500)
        )
        guard let lhs = withoutAction.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 280, height: 300)),
              let rhs = withAction.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 280, height: 300)) else {
            return XCTFail("Unable to crop rendered empty states")
        }
        XCTAssertEqual(lhs.dataProvider?.data as Data?, rhs.dataProvider?.data as Data?,
                       "Adding an action must not shift the empty-state icon/title/description")
    }

    func test_panelEmptyCopy_isLocalizedAndContainsNoDevelopmentPlaceholder() {
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
            let title = L10n.string("workspace.panel.empty.title", locale: locale)
            let description = L10n.string("workspace.panel.empty.desc", locale: locale)
            XCTAssertNotEqual(title, "workspace.panel.empty.title")
            XCTAssertNotEqual(description, "workspace.panel.empty.desc")
            XCTAssertFalse(description.localizedCaseInsensitiveContains("later update"))
            XCTAssertFalse(description.contains("后续版本"))
        }
    }

    private func makeSessions(machineName: String) -> SessionsManager {
        let defaults = UserDefaults(suiteName: "WorkspaceUIRegressionTests.\(UUID().uuidString)")!
        let machineStore = MachineStore(defaults: defaults)
        machineStore.add(MachineConfig(displayName: machineName, relayURL: "wss://example.test",
                                       sessionId: "session", devIdentityPubB64: "key"))
        return SessionsManager(machineStore: machineStore, transportFactory: { _ in MockTransport() })
    }

    private func mount(_ view: some View, size: CGSize) -> UIWindow {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        controller.view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        drainRunLoop()
        controller.view.layoutIfNeeded()
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func drainRunLoop() {
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out")
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private func responderChain(from responder: UIResponder) -> [UIResponder] {
        var result: [UIResponder] = []
        var current: UIResponder? = responder
        while let value = current {
            result.append(value)
            current = value.next
        }
        return result
    }

    private func commandReturn(in responders: [UIResponder]) -> UIKeyCommand? {
        for responder in responders {
            guard let commands = responder.keyCommands else { continue }
            for command in commands {
                let isReturn = command.input == "\r" || command.input == "\n"
                if isReturn && command.modifierFlags.contains(.command) { return command }
            }
        }
        return nil
    }

    // （plainReturn helper 已随旧「裸 Return=换行」行为锁删除——新行为经 shouldChangeTextIn 拦截，
    //   不注册 UIKeyCommand，该探测已无意义。）

    private func renderedImage(_ view: some View, size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground)))
        renderer.scale = 1
        return renderer.uiImage ?? UIImage()
    }
}

@MainActor
private final class ToolbarFrameRecorder {
    var machine: CGRect?
    var adjacent: CGRect?
}

private struct FrameReporter: View {
    let report: @MainActor (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear.onAppear { report(proxy.frame(in: .global)) }
        }
    }
}

// review C2 回归锁的宿主（@Observable 不能声明在函数内,故置文件级）。
@Observable private final class ComposerEnabledFlipHolder { var enabled = false }

private struct ComposerEnabledFlipHost: View {
    let holder: ComposerEnabledFlipHolder
    let store: ConversationStore
    let draft: ComposerDraft
    var body: some View {
        ComposerView(store: store, draft: draft, isEnabled: holder.enabled)
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
    }
}
