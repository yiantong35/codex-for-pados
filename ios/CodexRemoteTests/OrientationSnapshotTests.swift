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
    private func snapshot(_ view: some View, size: CGSize, name: String, dir: String? = nil) -> UIWindow {
        let outDir = dir ?? self.outDir
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.backgroundColor = .systemBackground

        // 关键：把 hostingController 真正挂进一个 keyWindow 再渲染。
        // 否则 trait=compact，NavigationSplitView 列宽计算异常（三栏挤在半屏）。
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hc
        window.makeKeyAndVisible()

        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        // 给 SwiftUI 多个 runloop 周期完成 NavigationSplitView 列布局 + 导航栏/toolbar 异步装配。
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            hc.view.layoutIfNeeded()
        }

        // 渲染：挂进 window 拿到 regular size class（NavigationSplitView 展开三栏、列宽正确），
        // 用 layer.render 同步捕获当前 layer 树（三栏内容 / Form / 列分隔 / 大标题全部正确）。
        // 已知局限：drawHierarchy(afterScreenUpdates:true) 在 UIGraphicsImageRenderer 离屏上下文中
        // 恒返回空白（需真实屏幕渲染通道）；SwiftUI inline toolbar（右上角齿轮）由系统在独立
        // 渲染通道异步绘制，layer.render 离屏快照捕获不到。齿轮按钮的接入在源码层确认：
        // SettingsMenu 置于 ConnectionConfigView / RootSplitView 的 .toolbar(.topBarTrailing)，
        // 两个朝向同一份 toolbar 修饰符，故两朝向均接入（见报告）。
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }

        guard let png = image.pngData() else {
            XCTFail("PNG 编码失败: \(name)")
            return window
        }
        let path = "\(outDir)/\(name).png"
        FileManager.default.createFile(atPath: path, contents: png)
        XCTAssertGreaterThan(png.count, 1000, "PNG 过小疑似空白: \(name)")
        return window
    }

    // MARK: - mock 装配

    private func makeConnection() -> ConnectionStore {
        // disconnected 态即可：ConnectionConfigView 显示连接表单；
        // RootSplitView 的 SidebarView .task 在 phase != .ready 时直接 return，不影响三栏布局。
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
        store.setPendingApproval(threadId: "a1", pending: true)
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

    // MARK: - 场景 1：ConnectionConfigView（连接表单 + 右上角齿轮）

    func testConnectionConfigPortrait() {
        let view = NavigationStack { ConnectionConfigView() }
            .environment(makeConnection())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "connection-portrait")
    }

    func testConnectionConfigLandscape() {
        let view = NavigationStack { ConnectionConfigView() }
            .environment(makeConnection())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: landscape, name: "connection-landscape")
    }

    // MARK: - 场景 2：RootSplitView 三栏（左栏项目树有内容）

    func testRootSplitPortrait() {
        let view = RootSplitView()
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "split-portrait")
    }

    func testRootSplitLandscape() {
        let view = RootSplitView()
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
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
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
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
        projects.setPendingApproval(threadId: "a", pending: true)
        XCTAssertTrue(projects.isGrouped)
        // 新增本地化键必须可解析（解析失败会回落为键名本身）。
        let conv = String(localized: "sidebar.conversations", bundle: .main)
        XCTAssertNotEqual(conv, "sidebar.conversations", "缺少 sidebar.conversations 本地化键")
        let view = SidebarView(selectedThreadId: .constant(nil))
            .environment(projects)
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
            .environment(makeConnection())
            .environment(LocaleManager())   // SettingsMenu（侧栏 toolbar，Task 26）依赖
            .environment(ThemeManager())
        snapshot(view, size: portrait, name: "sidebar-flat", dir: "/tmp/sidebar")
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

    // MARK: - 场景 5b：右边栏占位视图 RightPanelView（Task 9）

    /// 右栏占位：本期裹共享空态（design D3），渲染不崩溃、PNG 非空，落 /tmp/workspace。
    func test_right_panel_snapshot() {
        let view = RightPanelView()
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(ActiveConversationHolder())
            .frame(width: 320, height: 600)
        snapshot(view, size: CGSize(width: 320, height: 600),
                 name: "right-panel", dir: "/tmp/workspace")
    }

    // MARK: - 场景 5c：下边栏占位 + 可拖高容器 BottomPanelView（Task 10）

    /// 下栏占位：顶部可拖把手 + 共享空态（design D4），渲染不崩溃、PNG 非空，落 /tmp/workspace。
    /// 拖动手势效果靠用户/UI 测试确认；clamp 高度逻辑已在 WorkspaceMetricsTests 单测覆盖。
    func test_bottom_panel_snapshot() {
        let view = BottomPanelView(height: .constant(WorkspaceMetrics.bottomPanelIdealHeight))
            .environment(LocaleManager())
            .environment(TerminalSession())
            .environment(makeConnection())
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
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: landscape, name: "workspace-default", dir: "/tmp/workspace")
    }

    /// 工作区全开态（右栏 + 下栏初始展开）：验证层级——左栏满高、下栏在 detail 区内。
    /// 用注入初始展开态的便利初始化器（见实现 Step 3）。
    func test_workspace_all_panels_snapshot() {
        let view = RootSplitView(initialRightOpen: true, initialBottomOpen: true)
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(TerminalSession())
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
}
