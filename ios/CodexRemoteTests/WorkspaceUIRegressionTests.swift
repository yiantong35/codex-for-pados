import XCTest
import SwiftUI
import UIKit
@testable import CodexRemote

@MainActor
final class WorkspaceUIRegressionTests: XCTestCase {
    func test_workspaceToolbar_exposesLabelsAndActionsInsideNavigationStack() {
        let sessions = makeSessions(machineName: "开发机器-一个足够长且包含中文的工作站名称-0123456789")
        let layout = WorkspaceLayoutStore()
        let view = NavigationStack {
            Color.clear
                .toolbar {
                    WorkspaceToolbar(
                        layout: layout,
                        isCreatingThread: false,
                        reduceMotion: true,
                        createThread: {}
                    )
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .environment(sessions)

        let window = mount(view, size: CGSize(width: 1_194, height: 834))
        defer { unmount(window) }
        let labels = accessibilityLabels(in: window)
        let locale = LocaleManager.currentLocale
        for key in [
            "tab.machine.switcher", "sidebar.newThread", "workspace.leftPanel.toggle",
            "workspace.bottomPanel.toggle", "workspace.summary.toggle",
            "workspace.rightPanel.toggle", "settings.accessibility"
        ] {
            XCTAssertTrue(labels.contains(L10n.string(key, locale: locale)),
                          "Missing rendered toolbar action: \(key). Found: \(labels.sorted())")
        }

        let settingsLabel = L10n.string("settings.accessibility", locale: locale)
        let settingsControl = descendants(of: window).compactMap { $0 as? UIControl }
            .first { $0.accessibilityLabel == settingsLabel }
        XCTAssertNotNil(settingsControl)
        settingsControl?.sendActions(for: .touchUpInside)
        drainRunLoop()
        XCTAssertTrue(layout.showSettings, "Rendered settings toolbar action must remain reachable")
    }

    func test_rootSplitView_runtimeInstallsWorkspaceToolbar() {
        let sessions = makeSessions(machineName: "M5 iPad Pro 工作机器")
        let view = RootSplitView()
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(TerminalSession())
            .environment(ConnectionStore(transportFactory: { _ in MockTransport() }))
            .environment(ProjectsStore())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ShortcutStore())
            .environment(TextScaleManager())
            .environment(sessions)
        let window = mount(view, size: CGSize(width: 834, height: 1_194))
        defer { unmount(window) }
        let labels = accessibilityLabels(in: window)
        for key in ["tab.machine.switcher", "sidebar.newThread", "settings.accessibility"] {
            XCTAssertTrue(labels.contains(L10n.string(key, locale: LocaleManager.currentLocale)),
                          "RootSplitView did not install runtime toolbar item \(key): \(labels.sorted())")
        }
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

    func test_composerPlainReturnInsertsNewlineWithoutSending() async throws {
        let transport = MockTransport()
        let rpc = JSONRPCClient(transport: transport)
        await transport.setAutoRespond(true)
        await rpc.start()
        let draft = ComposerDraft()
        let store = ConversationStore(rpc: rpc, threadId: "return-test")
        let view = ComposerView(store: store, draft: draft)
            .environment(EnvironmentStore())
            .environment(ShortcutStore())
        let window = mount(view, size: CGSize(width: 600, height: 180))
        defer { unmount(window) }

        guard let input = descendants(of: window).first(where: { $0 is UITextField || $0 is UITextView }) as? UITextInput else {
            return XCTFail("Composer must render a native text input")
        }
        guard let responder = input as? UIResponder else { return XCTFail("Text input must be a responder") }
        _ = responder.becomeFirstResponder()
        drainRunLoop()
        XCTAssertNil(plainReturn(in: responderChain(from: responder)),
                     "Composer must not register plain Return as a send key command")
        input.insertText("first")
        input.insertText("\n")
        input.insertText("second")
        drainRunLoop()
        XCTAssertEqual(draft.text, "first\nsecond")
        try await Task.sleep(for: .milliseconds(100))
        let sent = await transport.sent
        XCTAssertFalse(sent.contains { $0.contains("turn/start") },
                       "Plain Return must remain an editing action, not a send action")
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

    private func accessibilityLabels(in view: UIView) -> Set<String> {
        var labels = Set(descendants(of: view).compactMap(\.accessibilityLabel))
        for child in descendants(of: view) {
            for case let element as UIAccessibilityElement in child.accessibilityElements ?? [] {
                if let label = element.accessibilityLabel { labels.insert(label) }
            }
        }
        return labels
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

    private func plainReturn(in responders: [UIResponder]) -> UIKeyCommand? {
        for responder in responders {
            guard let commands = responder.keyCommands else { continue }
            for command in commands {
                let isReturn = command.input == "\r" || command.input == "\n"
                if isReturn && command.modifierFlags.isEmpty { return command }
            }
        }
        return nil
    }

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
