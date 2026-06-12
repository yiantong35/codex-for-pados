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

    /// 快照用 KeyManager：内存存储，确定性且不触碰 Keychain。
    @MainActor
    private func makeKeyManager() -> KeyManager {
        KeyManager(store: SnapshotKeyStore())
    }

    // MARK: - 场景 1：ConnectionConfigView（连接表单 + 右上角齿轮）

    func testConnectionConfigPortrait() {
        let view = NavigationStack { ConnectionConfigView() }
            .environment(makeConnection())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(makeKeyManager())
        snapshot(view, size: portrait, name: "connection-portrait")
    }

    func testConnectionConfigLandscape() {
        let view = NavigationStack { ConnectionConfigView() }
            .environment(makeConnection())
            .environment(LocaleManager())
            .environment(ThemeManager())
            .environment(makeKeyManager())
        snapshot(view, size: landscape, name: "connection-landscape")
    }

    // MARK: - 场景 1b：连接密钥区（生成前 / 生成后）
    //
    // 局限：usePrivateKey 是 ConnectionConfigView 的私有 @State，离屏快照点不了开关，
    // 故直接渲染抽出的生产组件 KeyAreaView（与开关打开后渲染的完全是同一个 View）。
    // 产出落 /tmp/keyui/。

    private func keyCard(_ km: KeyManager) -> some View {
        KeyAreaView()
            .environment(km)
            .environment(LocaleManager())
            .padding(24)
            .frame(maxWidth: 480)
            .background(Color(.secondarySystemGroupedBackground))
    }

    func testKeyAreaBeforeGenerate() {
        let km = makeKeyManager()   // 空存储 → hasKey=false
        snapshot(keyCard(km), size: CGSize(width: 480, height: 200), name: "key-before", dir: "/tmp/keyui")
    }

    func testKeyAreaAfterGenerate() {
        let km = makeKeyManager()
        km.generateIfNeeded()       // hasKey=true → 指纹 + 复制 + 安装提示 + 重新生成
        snapshot(keyCard(km), size: CGSize(width: 480, height: 360), name: "key-after", dir: "/tmp/keyui")
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
}

/// 快照专用 KeyManager 存储替身：内存态，避免快照触碰 Keychain。
private final class SnapshotKeyStore: KeyStoring {
    private var data: Data?
    func saveKey(_ value: Data) { data = value }
    func loadKey() -> Data? { data }
    func deleteKey() { data = nil }
}
