import XCTest
import SwiftUI
@testable import CodexRemote

/// 横竖屏适配验收（快照工具，非永久回归断言）。
///
/// 不能转活体模拟器（辅助功能权限受限），改用快照：UIHostingController + UIGraphicsImageRenderer
/// 把 SwiftUI 视图在指定 iPad 11" 尺寸渲染成 PNG，供人工目视检查布局。
///
/// 产出 PNG 落在 /tmp/orient/，命名 <场景>-<朝向>.png。
@MainActor
final class OrientationSnapshotTests: XCTestCase {

    // iPad 11"（11-inch iPad Pro / Air M2）逻辑点尺寸。
    private let portrait = CGSize(width: 834, height: 1194)
    private let landscape = CGSize(width: 1194, height: 834)

    private let outDir = "/tmp/orient"

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(atPath: outDir,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - 渲染 helper

    /// 把 view 在指定尺寸渲染成 PNG 写到 /tmp/orient/<name>.png，返回承载视图的 window。
    @discardableResult
    private func snapshot(_ view: some View, size: CGSize, name: String, dir: String? = nil,
                          keepWindowAlive: Bool = false, baseline: String? = nil) -> UIWindow {
        let outDir = dir ?? self.outDir
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.backgroundColor = .systemBackground

        // 关键：把 hostingController 真正挂进一个 keyWindow 再渲染，拿到 regular size class，
        // GeometryReader 读到全屏总宽（自绘三栏按 2/3 上界与列宽正确布局）。
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hc
        window.makeKeyAndVisible()
        defer {
            if !keepWindowAlive {
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        // 给 SwiftUI 多个 runloop 周期完成自绘三栏 GeometryReader 布局 + 顶栏 safeAreaInset 装配。
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            hc.view.layoutIfNeeded()
        }

        // 渲染：挂进 window 拿到 regular size class（自绘三栏容器 ResizableColumns 按 2/3 上界与列宽正确布局），
        // 用 layer.render 同步捕获当前 layer 树（三栏内容 / Form / 列分隔 / 大标题全部正确）。
        // 已知局限：drawHierarchy(afterScreenUpdates:true) 在 UIGraphicsImageRenderer 离屏上下文中
        // 恒返回空白（需真实屏幕渲染通道）。齿轮已不走系统 toolbar：现挂在自绘顶栏 topBar 的
        // HStack 内（RootSplitView），随 layer 树同步渲染即可捕获，两个朝向同一份自绘顶栏均接入（见报告）。
        let png: Data = autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.pngData { ctx in
                window.layer.render(in: ctx.cgContext)
            }
        }

        let path = "\(outDir)/\(name).png"
        FileManager.default.createFile(atPath: path, contents: png)
        XCTAssertGreaterThan(png.count, 1000, "PNG 过小疑似空白: \(name)")
        if let baseline { PerceptualSnapshot.assert(png, named: baseline) }
        return window
    }

    // MARK: - mock 装配

    func test_compact_right_panel_overlay_snapshot() {
        let view = ResizableColumns(
            leftWidth: .constant(220),
            rightWidth: .constant(280),
            leftVisible: true,
            rightVisible: true,
            lastRequested: .right,
            loadRevision: 0,
            onResizeEnded: {}
        ) {
            Color.red
        } center: {
            Color.green
        } right: {
            Color.blue
        }

        snapshot(view, size: CGSize(width: 320, height: 600),
                 name: "compact-right-overlay", dir: "/tmp/workspace")
    }

    private func makeConnection() -> ConnectionStore {
        // disconnected 态即可：RootSplitView 的 SidebarView .task 在 phase != .ready 时
        // 直接 return，不影响三栏布局。
        ConnectionStore(transportFactory: { _ in MockTransport() })
    }

    /// 造 2 个项目、每项目 2-3 条对话的 ProjectsStore，让左栏项目树有内容。
    private func makeProjects() -> ProjectsStore {
        let store = ProjectsStore()
        let now = Date().timeIntervalSince1970
        func t(_ id: String, _ cwd: String, _ name: String?, _ preview: String, _ ago: Double) -> ThreadSummary {
            ThreadSummary(id: id, sessionId: "s-\(id)", preview: preview, modelProvider: "openai",
                          createdAt: now - ago, updatedAt: now - ago, cwd: cwd, cliVersion: "0.1.0",
                          name: name)
        }
        store.ingest([
            t("w1", "/repo/web", "重构登录页", "把登录页迁移到新的设计系统并补充无障碍标签", 120),
            t("w2", "/repo/web", nil, "修复横屏下导航栏溢出的问题，需要检查 safe area", 3600),
            t("w3", "/repo/web", "样式微调", "调整按钮间距", 86400),
            t("a1", "/repo/app", "接入推送", "集成 APNs 并处理后台静默推送回执上报逻辑", 600),
            t("a2", "/repo/app", nil, "排查启动崩溃", 7200),
        ])
        store.handleStatusChanged(threadId: "a1", status: .active(activeFlags: [.waitingOnApproval]))
        return store
    }

    /// 构造一个 git 项目会话（有 gitInfo → 归入项目区）。
    private func gitThread(_ id: String, cwd: String, origin: String, ago: Double, name: String? = nil) -> ThreadSummary {
        let now = Date().timeIntervalSince1970
        return ThreadSummary(id: id, sessionId: "s-\(id)", preview: "预览 \(id)", modelProvider: "openai",
                             createdAt: now - ago, updatedAt: now - ago, cwd: cwd, cliVersion: "0.1.0",
                             name: name, gitInfo: GitInfoSummary(sha: nil, branch: "main", originUrl: origin))
    }

    /// 构造一条 loose 会话（无 gitInfo → 归入对话区）。
    private func looseThread(_ id: String, cwd: String, ago: Double, name: String? = nil) -> ThreadSummary {
        let now = Date().timeIntervalSince1970
        return ThreadSummary(id: id, sessionId: "s-\(id)", preview: "预览 \(id)", modelProvider: "openai",
                             createdAt: now - ago, updatedAt: now - ago, cwd: cwd, cliVersion: "0.1.0",
                             name: name, gitInfo: nil)
    }

    // MARK: - 场景 2：RootSplitView 三栏（左栏项目树有内容）

    func testRootSplitPortrait() {
        let view = RootSplitView()
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ShortcutStore())                 // T10
            .environment(makeSessions(machineCount: 2))   // T10：快捷键层读 SessionsManager
        snapshot(view, size: portrait, name: "split-portrait")
    }

    func testRootSplitLandscape() {
        let view = RootSplitView()
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ShortcutStore())                 // T10
            .environment(makeSessions(machineCount: 2))   // T10：快捷键层读 SessionsManager
        snapshot(view, size: landscape, name: "split-landscape")
    }

    /// Task 26：默认态主界面（inspector 默认隐藏 + 设置齿轮移侧栏 + 空态不显大占位）。
    /// RED 落在可判定行为：新增本地化键 `inspector.toggle` 必须可解析（解析失败回落为键名本身）。
    func test_rootsplit_default_layout_snapshot() {
        let value = String(localized: "inspector.toggle", bundle: .main)
        XCTAssertNotEqual(value, "inspector.toggle", "缺少 inspector.toggle 本地化键")
        // 目视反馈修复（Task 26）：侧栏收起后召回需显式侧栏开关，依赖新本地化键。
        let toggle = String(localized: "sidebar.toggle", bundle: .main)
        XCTAssertNotEqual(toggle, "sidebar.toggle", "缺少 sidebar.toggle 本地化键")
        let view = RootSplitView()
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ShortcutStore())                 // T10
            .environment(makeSessions(machineCount: 2))   // T10：快捷键层读 SessionsManager
        snapshot(view, size: landscape, name: "split-default-layout")
    }

    // MARK: - 场景 3：SidebarView 分组态 / 平铺态（Task 24）

    /// ≥2 项目 + loose 会话 → isGrouped=true：项目区(DisclosureGroup + 待批准徽标) + 「对话」Section。
    func test_sidebar_grouped_mode_snapshot() {
        let projects = ProjectsStore()
        projects.ingest([
            gitThread("a", cwd: "/repo/web-dev", origin: "o/web", ago: 120, name: "重构登录页"),
            gitThread("b", cwd: "/repo/web-dev", origin: "o/web", ago: 600),
            gitThread("c", cwd: "/repo/api", origin: "o/api", ago: 30, name: "接入推送"),
            looseThread("d", cwd: "/Volumes/mount", ago: 40, name: "随手对话"),
        ])
        projects.handleStatusChanged(threadId: "a", status: .active(activeFlags: [.waitingOnApproval]))
        XCTAssertTrue(projects.isGrouped)
        // 新增本地化键必须可解析（解析失败会回落为键名本身）。
        let conv = String(localized: "sidebar.conversations", bundle: .main)
        XCTAssertNotEqual(conv, "sidebar.conversations", "缺少 sidebar.conversations 本地化键")
        let view = SidebarView(selectedThreadId: .constant(nil))
            .environment(projects)
            .environment(ActiveConversationHolder())
            .environment(EnvironmentStore())
            .environment(makeConnection())
            .environment(LocaleManager())   // SettingsMenu（侧栏 toolbar，Task 26）依赖
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "sidebar-grouped", dir: "/tmp/sidebar")
    }

    /// 仅 1 项目 → isGrouped=false：allThreadsSorted 平铺。
    func test_sidebar_flat_mode_snapshot() {
        let projects = ProjectsStore()
        projects.ingest([
            gitThread("a", cwd: "/repo/web-dev", origin: "o/web", ago: 120, name: "重构登录页"),
            gitThread("b", cwd: "/repo/web-dev", origin: "o/web", ago: 600),
            looseThread("d", cwd: "/Volumes/mount", ago: 40, name: "随手对话"),
        ])
        XCTAssertFalse(projects.isGrouped)
        let view = SidebarView(selectedThreadId: .constant(nil))
            .environment(projects)
            .environment(ActiveConversationHolder())
            .environment(EnvironmentStore())
            .environment(makeConnection())
            .environment(LocaleManager())   // SettingsMenu（侧栏 toolbar，Task 26）依赖
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "sidebar-flat", dir: "/tmp/sidebar",
                 baseline: "sidebar-flat")
    }

    func test_composer_compact_accessibility_visual_baseline() {
        let rpc = JSONRPCClient(transport: MockTransport())
        let store = ConversationStore(rpc: rpc, threadId: "visual-composer")
        let view = ComposerView(store: store, draft: ComposerDraft())
            .environment(EnvironmentStore())
            .environment(\.dynamicTypeSize, .accessibility3)
        snapshot(view, size: CGSize(width: 320, height: 220), name: "composer-compact-a11y",
                 dir: "/tmp/visual-regression", baseline: "composer-compact-a11y")
    }

    func test_mcp_actions_compact_accessibility_visual_baseline() throws {
        let params = #"{"threadId":"t","turnId":"turn","serverName":"github","mode":"url","message":"Authorize access to your repository","url":"https://example.com/oauth","elicitationId":"e-1"}"#
        let object = try JSONSerialization.jsonObject(with: Data(params.utf8))
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": "visual-mcp", "method": ServerRequestMethod.mcpElicitation, "params": object,
        ])
        guard case .request(let request) = try JSONDecoder().decode(JSONRPCMessage.self, from: requestData)
        else { return XCTFail("Expected MCP request") }
        let card = try McpElicitationCard(request: request)
        let view = McpElicitationCardView(card: card)
            .environment(McpElicitationStore())
            .environment(\.dynamicTypeSize, .accessibility3)
        snapshot(view, size: CGSize(width: 320, height: 680), name: "mcp-compact-a11y",
                 dir: "/tmp/visual-regression", baseline: "mcp-compact-a11y")
    }

    // MARK: - 场景 4：InspectorView 右栏简态（Task 25）

    /// 选中线程 → Inspector 展示 cwd/branch/model；新增本地化键必须可解析。
    func test_inspector_selected_thread_snapshot() {
        // 新增本地化键解析失败会回落为键名本身。
        for key in ["inspector.environment", "inspector.cwd", "inspector.branch",
                    "inspector.model", "inspector.empty"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
        let thread = gitThread("ins1", cwd: "/repo/web-dev", origin: "o/web", ago: 60, name: "重构登录页")
        let view = InspectorView(thread: thread)
            .environment(LocaleManager())
        snapshot(view, size: portrait, name: "inspector-selected", dir: "/tmp/inspector")
    }

    /// 未选中线程 → Inspector 显示占位（不崩溃，PNG 非空）。
    func test_inspector_empty_snapshot() {
        let view = InspectorView(thread: nil)
            .environment(LocaleManager())
        snapshot(view, size: portrait, name: "inspector-empty", dir: "/tmp/inspector")
    }

    // MARK: - 场景 5：共享面板空态视图 PanelEmptyState（Task 7）

    /// 共享空态视图：渲染不崩溃、PNG 非空，落 /tmp/workspace。
    /// RED 落可判定点：空态标题/描述本地化键必须可解析（解析失败回落为键名本身）。
    func test_panel_empty_state_snapshot() {
        for key in ["workspace.panel.empty.title", "workspace.panel.empty.desc"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
        let view = PanelEmptyState()
            .environment(LocaleManager())
            .environment(ThemeManager())
            .frame(width: 320, height: 240)
        snapshot(view, size: CGSize(width: 320, height: 240),
                 name: "panel-empty", dir: "/tmp/workspace")
    }

    // MARK: - 场景 5b：右边栏容器视图 RightPanelContainerView（Task 9）

    /// 右栏容器：tab 条 + 审查 tab（design D1/D3），渲染不崩溃、PNG 非空，落 /tmp/workspace。
    func test_right_panel_snapshot() {
        let view = RightPanelContainerView()
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ActiveConversationHolder())
            .environment(ApprovalStore())
            .environment(UserInputStore())
            .environment(McpElicitationStore())
            .environment(EnvironmentStore())
            .environment(SideChatStore())
            .environment(makeConnection())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(WorkspaceLayoutStore())   // T10：右栏读布局 store 消费意图
            .environment(ShortcutStore())          // M1：右栏读快捷键 store 承载全屏退出键
            .frame(width: 320, height: 600)
        let window = snapshot(view, size: CGSize(width: 320, height: 600),
                              name: "right-panel", dir: "/tmp/workspace", keepWindowAlive: true)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // D9：不再止于「PNG 非空」——断言窄宽(320pt)下右栏无横向溢出/裁剪（P1#2 逃逸根因）。
        // 环境约束（见 RightPanelTabsLayoutTests）：离屏 host 下纯 SwiftUI Button 不稳定暴露 UIKit 命中区，
        // 故核心断言=已命中的真实控件 maxX ≤ 容器宽（不溢出）+ tab 入口完整性（编译期）+ 挂载不崩溃。
        let hitRects = Self.hittableRects(in: window)
            .filter { $0.width > 0 && $0.height > 0 }
        XCTAssertGreaterThan(hitRects.count, 0, "至少应命中容器自身，挂载异常")
        for r in hitRects {
            XCTAssertLessThanOrEqual(r.maxX, 320.5, "右栏命中区不应溢出容器 320pt（P1#2 裁剪回归）：\(r)")
        }
        XCTAssertEqual(RightPanelTab.allCases.count, 3, "右栏三 tab 入口完整")
    }

    /// 递归收集响应交互的子视图 frame（转换到根坐标）。与 RightPanelTabsLayoutTests 同款遍历，
    /// 离屏 host 下纯 SwiftUI Button 结构性失明属已知限制（见该文件说明），保留 maxX 溢出断言为核心。
    private static func hittableRects(in root: UIView) -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ v: UIView) {
            if v.isUserInteractionEnabled, !(v is UIWindow),
               v.gestureRecognizers?.isEmpty == false || v is UIControl {
                out.append(v.convert(v.bounds, to: root))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    // MARK: - 场景 5c：下边栏占位 + 可拖高容器 BottomPanelView（Task 10）

    /// 下栏占位：顶部可拖把手 + 共享空态（design D4），渲染不崩溃、PNG 非空，落 /tmp/workspace。
    /// 拖动手势效果靠用户/UI 测试确认；clamp 高度逻辑已在 WorkspaceMetricsTests 单测覆盖。
    func test_bottom_panel_snapshot() {
        let view = BottomPanelView(height: .constant(WorkspaceMetrics.bottomPanelIdealHeight))
            .environment(LocaleManager())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(ClipboardPolicyStore())          // #1：远端剪贴板写门控存储
            .frame(width: 800, height: 260)
        snapshot(view, size: CGSize(width: 800, height: 260),
                 name: "bottom-panel", dir: "/tmp/workspace")
    }

    // MARK: - 场景 6：摘要悬浮浮层内容 SummaryPopoverView（Task 8）

    /// 摘要浮层有数据态：diff / cwd / plan / 任务都渲染，PNG 非空。
    func test_summary_popover_with_data_snapshot() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .fileChange(id: "f1", file: "a.swift", added: 12, removed: 4, diff: ""),
            .commandExecution(id: "c1", command: "swift build", output: "",
                              status: .completed, exitCode: 0, durationMs: 9),
        ]
        state.plan = [
            TurnPlanStep(step: "读代码", status: .completed),
            TurnPlanStep(step: "写测试", status: .inProgress),
        ]
        let thread = gitThread("sum1", cwd: "/repo/web-dev", origin: "o/web", ago: 60, name: "重构")
        let view = SummaryPopoverView(state: state, thread: thread)
            .environment(LocaleManager())
            .frame(width: 360, height: 480)
        snapshot(view, size: CGSize(width: 360, height: 480),
                 name: "summary-with-data", dir: "/tmp/workspace")
    }

    /// 摘要浮层空态：无 state / 无 thread → 空态占位，不崩溃。
    func test_summary_popover_empty_snapshot() {
        let view = SummaryPopoverView(state: nil, thread: nil)
            .environment(LocaleManager())
            .frame(width: 360, height: 200)
        snapshot(view, size: CGSize(width: 360, height: 200),
                 name: "summary-empty", dir: "/tmp/workspace")
    }

    // MARK: - 场景 6c：进度卡片 ProgressCardBar（turn-progress-card 4.1/4.2）

    /// 收起小条有数据态：plan N/M 步 + X 文件 +A −B（千位分隔、+绿 −红）。
    /// 验收 4.1：运行中显示步骤+文件数+行数，数字配色与千位分隔正确。
    func test_progress_card_collapsed_snapshot() {
        let progress = WorkspaceSummary.PlanProgress(steps: [
            TurnPlanStep(step: "读代码", status: .completed),
            TurnPlanStep(step: "写实现", status: .inProgress),
            TurnPlanStep(step: "补测试", status: .pending),
        ])
        let diff = WorkspaceSummary.DiffLineCounts(added: 1234, removed: 567, changedFiles: 8)
        let view = ProgressCardBar(progress: progress, diff: diff)
            .frame(width: 600, height: 120)
        snapshot(view, size: CGSize(width: 600, height: 120),
                 name: "progress-collapsed", dir: "/tmp/workspace")
    }

    /// 展开 overlay：plan 步骤列表 ✓完成/◌进行中/○待办，文案换行。
    /// 验收 4.2：展开场景。用注入初始展开态的便利初始化器。
    func test_progress_card_expanded_snapshot() {
        let progress = WorkspaceSummary.PlanProgress(steps: [
            TurnPlanStep(step: "读取并理解现有 diff 解析逻辑与边界用例", status: .completed),
            TurnPlanStep(step: "实现 TurnDiffStats 纯函数并接入 reducer", status: .inProgress),
            TurnPlanStep(step: "补充单元测试覆盖重命名与二进制文件", status: .pending),
        ])
        let diff = WorkspaceSummary.DiffLineCounts(added: 42, removed: 7, changedFiles: 3)
        let view = ProgressCardBar(progress: progress, diff: diff, initialExpanded: true)
            .frame(width: 600, height: 320)
        snapshot(view, size: CGSize(width: 600, height: 320),
                 name: "progress-expanded", dir: "/tmp/workspace")
    }

    /// 仅 plan（无 diff）：只显示步骤段，不显示文件/行数段。验收 4.2 仅-plan。
    func test_progress_card_plan_only_snapshot() {
        let progress = WorkspaceSummary.PlanProgress(steps: [
            TurnPlanStep(step: "分析需求", status: .inProgress),
            TurnPlanStep(step: "落地实现", status: .pending),
        ])
        let diff = WorkspaceSummary.DiffLineCounts(added: 0, removed: 0, changedFiles: 0)
        let view = ProgressCardBar(progress: progress, diff: diff)
            .frame(width: 600, height: 120)
        snapshot(view, size: CGSize(width: 600, height: 120),
                 name: "progress-plan-only", dir: "/tmp/workspace")
    }

    /// 仅 diff（无 plan）：只显示文件/行数段，不显示步骤段，且不可展开。验收 4.2 仅-diff。
    func test_progress_card_diff_only_snapshot() {
        let progress = WorkspaceSummary.PlanProgress(steps: [])
        let diff = WorkspaceSummary.DiffLineCounts(added: 88, removed: 12, changedFiles: 2)
        let view = ProgressCardBar(progress: progress, diff: diff)
            .frame(width: 600, height: 120)
        snapshot(view, size: CGSize(width: 600, height: 120),
                 name: "progress-diff-only", dir: "/tmp/workspace")
    }

    // MARK: - 场景 6b：当前会话共享持有者 ActiveConversationHolder（Task 12）

    /// 摘要 popover 接真实会话 state：用轻量 @Observable 持有者上提当前会话 state。
    /// 默认无活跃会话 → state 为 nil（摘要走空态）。
    func test_active_conversation_holder_default_nil() {
        let holder = ActiveConversationHolder()
        XCTAssertNil(holder.state)
    }

    // MARK: - 场景 7：RootSplitView 五窗口接线（Task 11）

    /// 工作区默认态：右/下栏隐藏、摘要关。顶栏 5 按钮辅助标签键须可解析。
    func test_workspace_default_layout_snapshot() {
        for key in ["workspace.leftPanel.toggle", "workspace.bottomPanel.toggle",
                    "workspace.rightPanel.toggle", "workspace.summary.toggle"] {
            let v = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(v, key, "缺少 \(key)")
        }
        let view = RootSplitView()
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(UserInputStore())
            .environment(McpElicitationStore())
            .environment(SideChatStore())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(FileBrowserStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ShortcutStore())                 // T10
            .environment(makeSessions(machineCount: 2))   // T10：快捷键层读 SessionsManager
        snapshot(view, size: landscape, name: "workspace-default", dir: "/tmp/workspace")
    }

    /// 工作区全开态（右栏 + 下栏初始展开）：验证层级——左栏满高、下栏在 detail 区内。
    /// 用注入初始展开态的便利初始化器（见实现 Step 3）。
    func test_workspace_all_panels_snapshot() {
        let view = RootSplitView(initialRightOpen: true, initialBottomOpen: true)
            .environment(EnvironmentInspectorModel())
            .environment(EnvironmentStore())
            .environment(ApprovalStore())
            .environment(UserInputStore())
            .environment(McpElicitationStore())
            .environment(SideChatStore())
            .environment(TerminalSession())
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(FileBrowserStore())
            .environment(SideChatStore())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(TerminalSession())
            .environment(ShortcutStore())                 // T10
            .environment(makeSessions(machineCount: 2))   // T10：快捷键层读 SessionsManager
            .environment(ClipboardPolicyStore())          // #1：下栏含终端，读远端剪贴板写门控存储
        snapshot(view, size: landscape, name: "workspace-all-open", dir: "/tmp/workspace")
    }

    /// 工作区新增本地化键必须可解析（解析失败回落键名本身）。
    func test_workspace_localization_keys_present() {
        for key in ["workspace.leftPanel.toggle", "workspace.bottomPanel.toggle",
                    "workspace.rightPanel.toggle", "workspace.summary.toggle",
                    "workspace.panel.empty.title", "workspace.panel.empty.desc",
                    "workspace.summary.title", "workspace.summary.diff",
                    "workspace.summary.cwd", "workspace.summary.progress",
                    "workspace.summary.tasks", "workspace.summary.empty"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
    }

    // MARK: - 场景 8：多机器 tab 容器视图横竖屏快照（Task 12）

    /// 构造带 N 台机器的 SessionsManager（可选高亮某台），供 tab 容器新视图快照注入。
    private func makeSessions(machineCount: Int, activeIndex: Int? = nil) -> SessionsManager {
        let d = UserDefaults(suiteName: "snap.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        for i in 0..<machineCount {
            store.add(MachineConfig(displayName: "机器\(i + 1)", relayURL: "wss://h\(i)",
                                    sessionId: "s\(i)", devIdentityPubB64: "pk\(i)"))
        }
        let mgr = SessionsManager(machineStore: store,
                                  transportFactory: { _ in MockTransport() })
        if let idx = activeIndex, idx < store.machines.count {
            mgr.setActive(store.machines[idx].id)
        }
        return mgr
    }

    private let mcDir = "/tmp/multiconn"

    /// 零机器引导页：图标 + 标题 + 主按钮居中卡片，横竖屏均不崩、PNG 非空。
    func test_onboarding_portrait_snapshot() {
        let view = OnboardingView().environment(makeSessions(machineCount: 0))
        snapshot(view, size: portrait, name: "onboarding-portrait", dir: mcDir)
    }

    func test_onboarding_landscape_snapshot() {
        let view = OnboardingView().environment(makeSessions(machineCount: 0))
        snapshot(view, size: landscape, name: "onboarding-landscape", dir: mcDir)
    }

    /// tab 栏多 tab（3 台，高亮第 2 台）：横向 tab 条整体布局横竖屏均不崩、PNG 非空。
    /// 圆点各色不在此覆盖（依赖 Session 内部 status 难在快照构造）——TabIndicator 各态由
    /// TabIndicatorTests 单测覆盖、DotView 渲染由 TabBarViewTests 覆盖，此处只验 tab 栏整体布局。
    func test_tabBar_portrait_snapshot() {
        let view = TabBarView().environment(makeSessions(machineCount: 3, activeIndex: 1))
        snapshot(view, size: portrait, name: "tabbar-portrait", dir: mcDir)
    }

    func test_tabBar_landscape_snapshot() {
        let view = TabBarView().environment(makeSessions(machineCount: 3, activeIndex: 1))
        snapshot(view, size: landscape, name: "tabbar-landscape", dir: mcDir)
    }

    /// 加机器表单：字段 + 公钥块居中卡片（内含 NavigationStack + toolbar），横竖屏均不崩、PNG 非空。
    func test_machineForm_portrait_snapshot() {
        let view = MachineFormView().environment(makeSessions(machineCount: 0))
        snapshot(view, size: portrait, name: "machineform-portrait", dir: mcDir)
    }

    func test_machineForm_landscape_snapshot() {
        let view = MachineFormView().environment(makeSessions(machineCount: 0))
        snapshot(view, size: landscape, name: "machineform-landscape", dir: mcDir)
    }

    // MARK: - 场景 9：快捷键设置分区（T10/Task 13）

    /// 快捷键分区新增本地化键必须可解析（解析失败回落为键名本身）。
    func test_shortcut_localization_keys_present() {
        var keys = ["settings.shortcuts",
                    "shortcut.scope.global", "shortcut.scope.workspace", "shortcut.scope.form",
                    "shortcut.rebind", "shortcut.resetDefault", "shortcut.resetAll",
                    "shortcut.recording", "shortcut.fixed",
                    "shortcut.conflict.occupied", "shortcut.conflict.systemReserved"]
        keys += ShortcutAction.allCases.map { "shortcut.action.\($0.rawValue)" }
        for key in keys {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
    }

    /// 快捷键分区渲染不崩、PNG 非空。
    func test_shortcuts_section_snapshot() {
        let view = NavigationStack { ShortcutsSettingsSectionView() }
            .environment(ShortcutStore(defaults: UserDefaults(suiteName: "snap.sc.\(UUID().uuidString)")!))
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "shortcuts-section", dir: "/tmp/settings")
    }
}
