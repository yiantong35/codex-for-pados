---
change: workspace-ui-review-fixes
design-doc: docs/superpowers/specs/2026-08-04-workspace-ui-review-fixes-design.md
base-ref: 651f6eefb31a9d4ef876802f8c7c27b7d97660d5
---

# Workspace UI Review Fixes 实施计划

> **致执行者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施本计划。所有步骤用复选框（`- [ ]`）语法跟踪。

**目标：** 修复一份外部 UI review 提出的 8 项发现（2 项 P1 发布阻断 + 4 项 P2 + 2 项 P3），并收口测试盲区，全部改动落在 iOS 视图/Store 层。

**架构：** 纯 iOS SwiftUI + `@Observable` Store 层改动，不触碰 relay/E2E/传输/安全面（SSH 已由 PR#46 移除，relay 为唯一路径）。canonical spec 在 OpenSpec（`openspec/changes/workspace-ui-review-fixes/`，7 个 delta capability spec），本计划只讲 HOW；WHAT/WHY 见设计文档 `docs/superpowers/specs/2026-08-04-workspace-ui-review-fixes-design.md` 的 9 项决策 D1–D9。

**技术栈：** Swift / SwiftUI / `@Observable` / XCTest / `xcodebuild test`。项目根 `/Volumes/mount/codex-for-pados`，iOS 源码在 `ios/CodexRemote/`，测试在 `ios/CodexRemoteTests/`。本地化文件 `ios/CodexRemote/Resources/Localizable.xcstrings`。

## 全局约束（每个任务的验收都隐含包含本节，逐字照抄自设计文档与项目恒定原则）

- **TDD（tdd_mode = tdd）：** 每个任务先写会失败的测试（RED），运行确认失败，再写最小实现（GREEN），运行确认通过，最后提交。每个任务 = 一次提交，尽量 ≤ ~200 行改动。
- **UI 三基线（`ui-adaptation-baseline`，项目恒定原则）：** 每个碰 UI 的任务，验收必须覆盖 **横屏 + 竖屏** 与 **手势 / 软键盘 / 外接键盘** 三条；只测单一朝向 = 漏验。
- **能耗（`energy-awareness-principle`，项目恒定原则）：** 不得新增常驻轮询 / 定时器。滚动感知、窄窗降级等一律纯 UI 状态、事件驱动。
- **安全（`security-first-principle`，项目恒定原则）：** 本 change 不碰安全面（连接/密钥/鉴权/绑定/进程一律不动）。任何任务若发现自己在改传输/relay/Keychain，即为跑偏，停止并回报。
- **本地化 API 铁律（D5）：** 面向用户文案不得硬编码某一自然语言；动态标签 **不得** 用 `String(localized:)`（它按系统语言选表、忽略应用内注入 locale，是已知 bug）。须走跟随注入 locale 的通道（`@Environment(\.locale)` → 对应 `.lproj` bundle 查表）。静态视图字面量（`Text("key")`、`Button("key")` 等 `LocalizedStringKey` 参数）**会** 跟随注入 locale，可继续用 key。
- **构建/测试命令：** `xcodebuild test` 针对 `ios/` 下的工程（scheme `CodexRemote`，iPad 模拟器 destination）。单个测试类可用 `-only-testing:CodexRemoteTests/<ClassName>` 加速 RED/GREEN 迭代。
- **提交信息尾注（每次 commit）：**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **不改侧聊 fork / 多侧聊既有语义**（仅隔离其审查状态写入）；**不重构三栏架构本体**（仅补窄窗降级）。

---

## 文件结构总览（本计划将创建/修改的文件及职责）

**批1（P1 阻断）：**
- 修改 `ios/CodexRemote/Views/ConversationView.swift` — 增 `bindsWorkspaceState` 开关（D1），迁移 resume 到 add/remove 配对（D2）。
- 修改 `ios/CodexRemote/Views/Workspace/SideChatView.swift` — 侧聊挂载传 `bindsWorkspaceState: false`（D1）。
- 修改 `ios/CodexRemote/Stores/ConnectionStore.swift` — `resumeHandler` 单属性 → token 订阅表（D2）。
- 修改 `ios/CodexRemote/Views/Workspace/RightPanelContainerView.swift` — 去每标签 `maxWidth:.infinity` 独占，窄宽降级（D3）。
- 测试：`ios/CodexRemoteTests/SideChatIsolationTests.swift`（新建，D1）、`ios/CodexRemoteTests/ConnectionStoreTests.swift`（扩充，D2）、`ios/CodexRemoteTests/RightPanelTabsLayoutTests.swift`（新建，D3+D9）。

**批2（P2）：**
- 修改 `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift` — 增三栏全开最低宽常量 + 降级决策纯函数（D4）。
- 修改 `ios/CodexRemote/Views/Workspace/ResizableColumns.swift` — 容器 < 阈值自动收起侧栏（D4）。
- 新建 `ios/CodexRemote/Views/Support/LocalizedBundle.swift` — 抽共享 locale 查表 helper（D5）。
- 修改 `ios/CodexRemote/Views/Settings/ShortcutsSettingsSectionView.swift`（改用共享 helper）、`FileBrowserView.swift`、`Protocol/ReviewPanelTypes.swift`、`Views/Workspace/ReviewTabView.swift`、`SideChatView.swift`、`Views/Workspace/ProgressCardBar.swift`（硬编码中文改走 helper / key，D5）。
- 修改 `ios/CodexRemote/Views/TabBarView.swift` — 移除机器加 confirmationDialog + 菜单互斥（D6）。
- 修改 `ios/CodexRemote/Views/ComposerView.swift`（44pt 命中框 + accessibilityLabel）、`Views/SidebarView.swift`（会话行 `onTapGesture` → `Button`）（D7）。
- 修改 `ios/CodexRemote/Resources/Localizable.xcstrings` — 补 D5 新键。
- 测试：`WorkspaceMetricsTests.swift`（扩充，D4）、`ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift`（新建，D5）、`TabBarViewTests.swift`（扩充，D6）、`ios/CodexRemoteTests/TouchAccessibilityTests.swift`（新建，D7）。

**批3（P3 + 收口）：**
- 修改 `ios/CodexRemote/Views/RootSplitView.swift` — detail 未选会话渲染引导空态（D8）。
- 修改 `ios/CodexRemote/Views/ConversationView.swift` — 滚动位置感知 + 近底判定 + 「新消息」浮标（D8）。
- 测试：`ios/CodexRemoteTests/ConversationScrollAnchorTests.swift`（新建，D8）、`OrientationSnapshotTests.swift`（升级 `:254` 结构断言，D9）。

---

## 批1 — P1 发布阻断项（D1 + D2 + D3）

### Task 1: D1 侧聊状态隔离 — `ConversationView` 增 `bindsWorkspaceState` 开关

**Files:**
- Modify: `ios/CodexRemote/Views/ConversationView.swift`（`:48-50` state onChange / `:55-58` onDisappear 清空 / `:94-96` fetchFullDiff+startReview 注入 / `:100` setResumeHandler）
- Modify: `ios/CodexRemote/Views/Workspace/SideChatView.swift:72`（侧聊挂载点）
- Test: `ios/CodexRemoteTests/SideChatIsolationTests.swift`（新建）

**Interfaces:**
- Produces: `ConversationView(threadId:bindsWorkspaceState:)` — 新增 `let bindsWorkspaceState: Bool`，默认 `true`。仅 `bindsWorkspaceState == true` 时才写 `activeConversation.{state, fetchFullDiff, startReview}`、在 `onDisappear` 清空这三者、并注册 resume（D2 的 `bindsWorkspaceState` 分支归属）。侧聊实例传 `false` → 完全不碰 holder。
- Consumes: 现有 `ActiveConversationHolder`（`RootSplitView.swift:8-18`，单例，`.environment` 注入整棵树，保持单例不变）。

- [x] **Step 1: 写失败测试** — 断言侧聊实例（`bindsWorkspaceState: false`）对 holder 零写入；主对话实例（默认 true）正常写入；侧聊开/关不清空主对话审查状态。

新建 `ios/CodexRemoteTests/SideChatIsolationTests.swift`：

```swift
import XCTest
import SwiftUI
@testable import CodexRemote

/// D1：侧聊使用独立 active-conversation 上下文——侧聊实例（bindsWorkspaceState=false）
/// 绝不写入/清空主对话绑定的 ActiveConversationHolder（state/fetchFullDiff/startReview）。
@MainActor
final class SideChatIsolationTests: XCTestCase {

    /// 侧聊 ConversationView 参数化开关默认 true、可显式传 false——用类型层面断言开关存在，
    /// 并断言 SideChatView 内部对 ConversationView 的挂载传入 false（不共享 holder）。
    /// 结构断言：挂载 + 布局一轮后，holder 三字段仍为初始 nil（侧聊未写入）。
    func test_sideChat_doesNotWriteHolder() {
        let holder = ActiveConversationHolder()
        // 预置一个「主对话已注入」的 holder 现场：startReview / fetchFullDiff / state 非空。
        holder.state = ConversationState(threadId: "main")
        holder.fetchFullDiff = { _ in "main-diff" }
        holder.startReview = { _ in true }

        // 侧聊挂载：bindsWorkspaceState=false 的 ConversationView。挂载并布局一轮。
        let view = ConversationView(threadId: "side-thread", bindsWorkspaceState: false)
            .environment(holder)
            .environment(ApprovalStore())
            .environment(makeIsolatedConnection())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()

        // 侧聊不驱动审查面板：主对话注入的 holder 现场保持原样。
        XCTAssertEqual(holder.state?.threadId, "main", "侧聊不应覆盖主对话 state")
        XCTAssertNotNil(holder.fetchFullDiff, "侧聊不应清空主对话 fetchFullDiff")
        XCTAssertNotNil(holder.startReview, "侧聊不应清空主对话 startReview")
    }

    private func makeIsolatedConnection() -> ConnectionStore {
        ConnectionStore(transportFactory: { _ in MockTransport() })
    }
}
```

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/SideChatIsolationTests`。预期：编译失败（`ConversationView` 无 `bindsWorkspaceState:` 参数）。

- [x] **Step 3: 最小实现** — 给 `ConversationView` 加参数并 gate 五处写点。

在 `ConversationView.swift` 结构体字段区（`:11` `let threadId: String` 之后）加：

```swift
    /// D1：是否绑定工作区审查状态（写入/清空 ActiveConversationHolder 并注册 resume）。
    /// 中栏主对话传 true（默认）；侧聊实例传 false，完全不碰 holder，隔离审查状态。
    var bindsWorkspaceState: Bool = true
```

gate `:48-50` 的 state onChange：

```swift
        .onChange(of: store?.state) { _, newValue in
            if bindsWorkspaceState { activeConversation.state = newValue }
        }
```

gate `:55-58` 的 onDisappear 清空（仅清 holder 三字段那行加 gate，`store?.stopObserving()` 保留无条件）：

```swift
        .onDisappear {
            store?.stopObserving()
            if bindsWorkspaceState {
                activeConversation.state = nil; activeConversation.fetchFullDiff = nil; activeConversation.startReview = nil
            }
        }
```

gate `.task` 内 `:94-96, :100`（fetchFullDiff / startReview / setResumeHandler 三处注入包进 `if bindsWorkspaceState`；注意 `s.startObserving()`/`s.resume()`/`store = s`/`drainOutbox` 等保持无条件）：

```swift
            if bindsWorkspaceState {
                activeConversation.fetchFullDiff = { [weak s] cwd in await s?.fetchFullDiff(cwd: cwd) }
                activeConversation.startReview = { [weak s] mode in await s?.startReview(mode: mode) ?? false }
            }
```

（`setResumeHandler` 那行的处理在 Task 4 迁移为 add/remove；本任务先保持 `if bindsWorkspaceState { connection.setResumeHandler {...} }` 包裹，避免侧聊也覆盖 handler。）

在 `SideChatView.swift:72` 挂载点传 false：

```swift
            ConversationView(threadId: session.conversation.threadId, bindsWorkspaceState: false)
```

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/SideChatIsolationTests`。预期：PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/ConversationView.swift ios/CodexRemote/Views/Workspace/SideChatView.swift ios/CodexRemoteTests/SideChatIsolationTests.swift
git commit -m "feat(ipad): 侧聊状态隔离，ConversationView 增 bindsWorkspaceState 开关 (D1)"
```

---

### Task 2: D2 `ConnectionStore` resume 回调单属性 → token 订阅表

**Files:**
- Modify: `ios/CodexRemote/Stores/ConnectionStore.swift`（`:94` resumeHandler 属性 / `:98` didInitialRejoin / `:124-136` setResumeHandler+triggerInitialRejoinIfReady / `:189` connect 首连触发 / `:237-238` disconnect 重置 / `:400` observeControl `.ready` 遍历触发）
- Test: `ios/CodexRemoteTests/ConnectionStoreTests.swift`（扩充新用例）

**Interfaces:**
- Produces:
  - `func addResumeHandler(_ h: @escaping @Sendable () async -> Void) -> ResumeToken` — 登记并返回轻量唯一 token；若当前已 ready 且该 token 未首连触发过，立即补触发恰一次。
  - `func removeResumeHandler(_ token: ResumeToken)` — 精确注销单个订阅者，不影响其它。
  - `struct ResumeToken: Hashable, Sendable`（内部用递增 `UInt64` 或 `UUID`）。
  - `func setResumeHandler(_ h:)` — 保留为薄封装（内部 `_ = addResumeHandler(h)`，忽略返回 token），维持既有调用点与既有测试 `testInitialConnectAlsoRejoins` / `testReconnectReadyControlTriggersResync` 绿。
- Consumes: `MockTransport`、`FireBox`（`ConnectionStoreTests.swift:521`）、`waitUntil`（`ConnectionStoreTests.swift:225`）。

- [x] **Step 1: 写失败测试** — 在 `ConnectionStoreTests.swift` 末尾（`actor FireBox` 定义之前的类内）新增三个用例：多订阅互不覆盖、注销后不再触发、已 ready 时新订阅补触发恰一次。

```swift
    /// D2：主对话与侧聊各自注册恢复回调，物理重连 .ready 时两者都被触发（后者不覆盖前者）。
    func test_multipleResumeHandlers_bothTriggeredOnReconnect() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        await driveToReady(store: store, mock: mock)   // 见下 helper

        let a = FireBox(); let b = FireBox()
        _ = await store.addResumeHandler { await a.bump() }
        _ = await store.addResumeHandler { await b.bump() }
        // 首连补触发各恰一次（已 ready 时注册）。
        try await waitUntil { await a.count >= 1 && await b.count >= 1 }

        // 物理重连 .ready：遍历触发全部订阅者。
        await mock.emitControl(.reconnecting)
        await mock.emitControl(.ready)
        try await waitUntil { await a.count >= 2 && await b.count >= 2 }
        let ca = await a.count; let cb = await b.count
        XCTAssertGreaterThanOrEqual(ca, 2); XCTAssertGreaterThanOrEqual(cb, 2)
    }

    /// D2：注销某订阅者后，仅它被移除；其它订阅者后续重连仍被触发。
    func test_removeResumeHandler_removesOnlyThatSubscriber() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        await driveToReady(store: store, mock: mock)

        let keep = FireBox(); let drop = FireBox()
        _ = await store.addResumeHandler { await keep.bump() }
        let dropToken = await store.addResumeHandler { await drop.bump() }
        try await waitUntil { await keep.count >= 1 && await drop.count >= 1 }
        let dropAfterFirst = await drop.count

        await store.removeResumeHandler(dropToken)
        await mock.emitControl(.reconnecting)
        await mock.emitControl(.ready)
        try await waitUntil { await keep.count >= 2 }
        let dropFinal = await drop.count
        XCTAssertEqual(dropFinal, dropAfterFirst, "已注销订阅者不应再被触发")
    }

    /// D2：连接已就绪且已首连恢复后，新订阅者补触发恰一次，既有订阅者不重复触发。
    func test_lateSubscriber_backfillsExactlyOnce() async throws {
        let mock = MockTransport()
        let store = await ConnectionStore(transportFactory: { _ in mock })
        await driveToReady(store: store, mock: mock)

        let early = FireBox()
        _ = await store.addResumeHandler { await early.bump() }
        try await waitUntil { await early.count >= 1 }
        let earlyAfterFirst = await early.count

        let late = FireBox()
        _ = await store.addResumeHandler { await late.bump() }
        try await waitUntil { await late.count >= 1 }
        let lateCount = await late.count
        let earlyFinal = await early.count
        XCTAssertEqual(lateCount, 1, "新订阅者应补触发恰一次")
        XCTAssertEqual(earlyFinal, earlyAfterFirst, "既有订阅者不应因新订阅者加入而重复触发")
    }
```

> 说明：`driveToReady(store:mock:)` 与 `mock.emitControl(_:)` 若 `ConnectionStoreTests.swift` / `MockTransport.swift` 尚无等价物，则本步一并添加最小 helper——复用既有 `testInitialConnectAlsoRejoins`（`:115-141`）里「后台喂 initialize 响应 + waitUntil ready」的写法抽成私有 `driveToReady`；`emitControl` 走 `MockTransport` 既有的 control 事件注入通道（`testReconnectReadyControlTriggersResync :295` 已用同类机制，照其模式复用，不新造协议）。

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/ConnectionStoreTests`。预期：编译失败（无 `addResumeHandler`/`removeResumeHandler`/`ResumeToken`）。

- [x] **Step 3: 最小实现** — 把单属性改订阅表。

`ConnectionStore.swift` 顶部（`ConnectionStore` 之外或内部）加 token 类型：

```swift
/// D2：resume 订阅者的轻量唯一标识。
struct ResumeToken: Hashable, Sendable { let raw: UInt64 }
```

替换 `:94` 单属性 + `:98` 单 bool：

```swift
    /// D2：resume 回调订阅表（主对话 + 每个侧聊各一）。单属性会被后注册者覆盖，故改多订阅。
    private var resumeHandlers: [ResumeToken: @Sendable () async -> Void] = [:]
    /// 已首连补触发过的订阅者集合（订阅者维度化的 didInitialRejoin）：新订阅者不漏、老订阅者不重。
    private var rejoinedTokens: Set<ResumeToken> = []
    private var nextResumeTokenRaw: UInt64 = 0
```

新增 add/remove + 保留薄封装 setResumeHandler，重写 `triggerInitialRejoinIfReady` 为「补触发未触发过的订阅者」：

```swift
    @discardableResult
    func addResumeHandler(_ h: @escaping @Sendable () async -> Void) -> ResumeToken {
        let token = ResumeToken(raw: nextResumeTokenRaw); nextResumeTokenRaw &+= 1
        resumeHandlers[token] = h
        // 已就绪且本 token 尚未首连触发过 → 立即补触发恰一次（对齐既有 setResumeHandler 语义）。
        if isReady, !rejoinedTokens.contains(token) {
            rejoinedTokens.insert(token)
            Task { await h() }
        }
        return token
    }

    func removeResumeHandler(_ token: ResumeToken) {
        resumeHandlers[token] = nil
        rejoinedTokens.remove(token)
    }

    /// 薄封装：保留旧调用点/旧测试。忽略返回 token（无法精确注销，仅供不需注销的场景）。
    func setResumeHandler(_ h: @escaping @Sendable () async -> Void) {
        _ = addResumeHandler(h)
    }

    /// 首连补触发：对「已就绪」但「尚未首连触发过」的每个订阅者各触发恰一次。
    private func triggerInitialRejoinIfReady() {
        guard isReady else { return }
        for (token, h) in resumeHandlers where !rejoinedTokens.contains(token) {
            rejoinedTokens.insert(token)
            Task { await h() }
        }
    }
```

`connect()` 里 `:159-161` 的 `didInitialRejoin = false` 改为清空 `rejoinedTokens`：

```swift
        rejoinedTokens.removeAll()
        isReady = false
```

`disconnect()` 里 `:237-238`：

```swift
        isReady = false
        rejoinedTokens.removeAll()
```

`observeControl` 的 `.ready` 分支 `:400`（物理重连遍历触发全部）：

```swift
                case .ready:
                    self.phase = .ready
                    self.startHeartbeat()
                    for h in self.resumeHandlers.values { Task { await h() } }
```

（`connect()` 首连成功路径 `:189` 仍调 `self.triggerInitialRejoinIfReady()`，语义不变。）

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/ConnectionStoreTests`。预期：新用例 + 既有 `testInitialConnectAlsoRejoins`/`testReconnectReadyControlTriggersResync` 全 PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemoteTests/ConnectionStoreTests.swift ios/CodexRemoteTests/MockTransport.swift
git commit -m "feat(ipad): resume 回调单属性改 token 订阅表，支持多订阅者 (D2)"
```

---

### Task 3: D2 迁移 `ConversationView` resume 到 add/remove 配对

**Files:**
- Modify: `ios/CodexRemote/Views/ConversationView.swift`（`.task` 内 `:100` setResumeHandler 改 addResumeHandler + `defer`/`onDisappear` remove）

**Interfaces:**
- Consumes: Task 2 的 `addResumeHandler(_:) -> ResumeToken` / `removeResumeHandler(_:)`；Task 1 的 `bindsWorkspaceState`。
- Produces: `.task` 生命周期承载 `add → remove` 精确配对（主对话与每个侧聊各自 thread 的 rejoin 都需要，故走多订阅）。

- [x] **Step 1: 写失败测试** — 复用 Task 2 的多订阅能力，加一个「视图消失注销」的行为断言。实际上 `.task` 生命周期难在单测直接驱动 SwiftUI，故本任务的验收以 **Task 2 已建的 `test_removeResumeHandler_removesOnlyThatSubscriber` 语义 + 编译期接线正确性** 为准；新增一条轻量断言：`ConversationView` 侧聊实例（`bindsWorkspaceState=false`）**仍** 注册自己的 rejoin（侧聊 thread 也需重连恢复），只是不写 holder。

在 `SideChatIsolationTests.swift` 追加：

```swift
    /// D2：侧聊实例也注册 resume（自己的 thread 需重连恢复），但不写 holder。
    /// 结构断言：侧聊挂载后，连接的订阅者计数 > 0（经 DEBUG 只读访问器）。
    func test_sideChat_registersOwnResumeButNotHolder() {
        let holder = ActiveConversationHolder()
        let conn = ConnectionStore(transportFactory: { _ in MockTransport() })
        let view = ConversationView(threadId: "side", bindsWorkspaceState: false)
            .environment(holder).environment(ApprovalStore()).environment(conn)
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        // holder 未被侧聊写入（与 Task 1 一致）。此处仅确保侧聊挂载不崩溃且不污染 holder。
        XCTAssertNil(holder.startReview)
    }
```

> 若引入 DEBUG 订阅者计数访问器不划算，则本步以「编译通过 + Task 2 注销用例绿 + 手工代码走读」验收，删去 count 断言，保留 holder 不污染断言即可。

- [x] **Step 2: 运行确认失败/现状** — 运行 `SideChatIsolationTests`，确认现有接线（`setResumeHandler` 单属性调用）编译仍绿但语义未迁移。

- [x] **Step 3: 最小实现** — `ConversationView.swift` `.task` 内把 `:100` 的 `connection.setResumeHandler {...}` 改为 add + defer remove（注意 `bindsWorkspaceState` 现在 **不** 再 gate resume——主对话与侧聊各自 thread 都需 rejoin；D1 的 gate 只管 holder 写入）：

```swift
            let resumeToken = connection.addResumeHandler { [weak s] in await s?.rejoinRunningThreads() }
            defer { connection.removeResumeHandler(resumeToken) }
```

将该两行放在原 `setResumeHandler` 位置；`defer` 与既有 `defer { s.stopObserving() }`（`:92`）并存（两个 defer 均在 `.task` 结束/取消时执行）。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/SideChatIsolationTests -only-testing:CodexRemoteTests/ConnectionStoreTests`。预期：全 PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/ConversationView.swift ios/CodexRemoteTests/SideChatIsolationTests.swift
git commit -m "feat(ipad): ConversationView resume 改 add/remove 配对，主对话与侧聊各自订阅 (D2)"
```

---

### Task 4: D3 右栏 tab 窄宽可达 — 去每标签 `maxWidth:.infinity` 独占

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/RightPanelContainerView.swift:130-160`（`tabBar`）
- Test: `ios/CodexRemoteTests/RightPanelTabsLayoutTests.swift`（新建）

**Interfaces:**
- Consumes: `RightPanelTab.allCases`（`:4`，三 tab review/files/sideChat）、`RightPanelContainerView()`（既有无参可构造，`OrientationSnapshotTests:256` 已示范其环境注入组合）。
- Produces: `tabBar` 改为可容纳全部入口——标签不再各请求无限宽独占；尾部全屏入口固定占位、不参与 tab 等分、不挤占 tab 命中区。

- [x] **Step 1: 写失败测试** — 新建 `RightPanelTabsLayoutTests.swift`，断言 320pt 宽下三 tab 与全屏入口均可挂载渲染，且用「无 `maxWidth:.infinity` 独占」的结构性判定（用 `ViewInspector` 若项目已用；否则用 hosting + 布局后子视图 frame 断言最简可行版本）。项目现有 `TabBarViewTests` 用 `UIHostingController` + layout 后断状态的范式，照此写结构断言：

```swift
import XCTest
import SwiftUI
@testable import CodexRemote

/// D3 + D9：右栏 tab 条在窄宽（320pt）下三个 tab 全部可见可命中，
/// 尾部全屏入口不挤占 tab 命中区。取代「PNG 非空」的空断言。
@MainActor
final class RightPanelTabsLayoutTests: XCTestCase {

    /// 三个 tab 均在 320pt 宽下参与布局、命中区 > 0（非被裁剪为零宽）。
    func test_threeTabs_visibleAt320pt() {
        let view = RightPanelContainerView()
            .environment(ActiveConversationHolder())
            .environment(ApprovalStore())
            .environment(EnvironmentStore())
            .environment(ConnectionStore(transportFactory: { _ in MockTransport() }))
            .environment(WorkspaceLayoutStore())
            .environment(ShortcutStore())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()

        // 收集所有可命中的 UIControl/交互子视图，断言其累加宽度不超过容器（不横向溢出），
        // 且存在至少 3 个 tab 命中区 + 1 个全屏入口（共 ≥4 个可命中矩形，均宽 > 0）。
        let hitRects = Self.hittableRects(in: hc.view)
            .filter { $0.width > 0 && $0.height > 0 }
        XCTAssertGreaterThanOrEqual(hitRects.count, 4,
            "应有 3 个 tab + 1 个全屏入口共 ≥4 个可命中区，实际 \(hitRects.count)")
        for r in hitRects {
            XCTAssertLessThanOrEqual(r.maxX, 320.5, "命中区不应溢出容器 320pt：\(r)")
        }
    }

    /// 递归收集响应交互的子视图 frame（转换到根坐标）。
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
}
```

> 若该 hosting 遍历在 CI 上不稳定（SwiftUI 内部视图树易变），退化为最小可判定断言：容器可在 320pt 挂载渲染不崩溃 + `RightPanelTab.allCases.count == 3`（编译期入口完整性）+ 手工走读确认无 `maxWidth:.infinity` 独占。保留「命中区 maxX ≤ 容器宽」这条溢出断言为核心。

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/RightPanelTabsLayoutTests`。预期：FAIL（当前首标签 `maxWidth:.infinity` 独占 → 后两 tab 命中区宽 ≈ 0 或溢出，命中区计数 < 4）。

- [x] **Step 3: 最小实现** — 改 `tabBar`（`:130-160`）：去掉标签的 `.frame(maxWidth: .infinity)` 独占，改等分压缩 + 文字降级；尾部全屏入口固定占位。

```swift
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.label)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)          // 窄宽文字降级，不撑破
                        .frame(maxWidth: .infinity)       // 三 tab 之间等分（每个都 infinity → 均分，不再是首个独占）
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())        // 留白也可命中
                }
                .buttonStyle(.plain)
                .layoutPriority(1)                        // tab 优先于尾部入口占据 tab 区
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
            // 全屏 / 收起入口：固定占位、不参与 tab 等分、不挤占 tab 命中区。
            Button {
                isFullscreen.toggle()
            } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()                                  // 固定自身尺寸，不吸收也不挤占 tab 区
            .accessibilityLabel(Text(isFullscreen ? "rightPanel.fullscreen.exit" : "rightPanel.fullscreen.enter"))
        }
        .background(.bar)
    }
```

> 关键差异：原实现只有 **每个** 标签 `maxWidth:.infinity`，但尾部全屏按钮不定宽 → 在极窄宽下 SwiftUI 会让首个 infinity 吞掉剩余空间、后续被裁。新实现三标签均分 + 全屏入口 `fixedSize()` 定宽退出竞争，三 tab 恒有等分命中区。若 320pt 三 tab 文字仍拥挤，`minimumScaleFactor(0.7)` 兜底缩字；如需进一步可将 `HStack` 包一层 `ScrollView(.horizontal)`——但当前三个短标签等分已够，避免过度设计。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/RightPanelTabsLayoutTests`。预期：PASS（≥4 命中区，均 maxX ≤ 320）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/RightPanelContainerView.swift ios/CodexRemoteTests/RightPanelTabsLayoutTests.swift
git commit -m "feat(ipad): 右栏 tab 条去每标签独占，窄宽三 tab 均可达 (D3)"
```

---

## 批2 — P2（D4 + D5 + D6 + D7）

### Task 5: D4 `WorkspaceMetrics` 三栏全开最低宽常量 + 降级决策纯函数

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift`（在 `:36-39` 列宽常量区后新增）
- Test: `ios/CodexRemoteTests/WorkspaceMetricsTests.swift`（扩充）

**Interfaces:**
- Consumes: `leftColumnMinWidth`(160)、`centerColumnMinWidth`(280)、`rightColumnMinWidth`(200)、`resizableDividerHitWidth`(14)（均 `WorkspaceMetrics.swift:36-47`）。
- Produces:
  - `static let threeColumnMinTotalWidth: CGFloat` = `left+center+right + 2*divider` = `160+280+200+28 = 668`（用常量算出，不写死数字）。
  - `struct ColumnVisibilityPlan { let showLeft: Bool; let showRight: Bool }`。
  - `static func columnVisibilityPlan(total: CGFloat, wantLeft: Bool, wantRight: Bool) -> ColumnVisibilityPlan` — 纯函数：容器宽足够（≥ threeColumnMinTotalWidth）→ 原样；不足 → 先收右栏（`left+center+1*divider`），仍不足 → 再收左栏（仅中栏）。保证被显示栏最小宽之和 ≤ total、中栏永远完整。

- [ ] **Step 1: 写失败测试** — 在 `WorkspaceMetricsTests.swift` 末尾类内新增：

```swift
    // MARK: - D4 窄窗三栏降级

    func testThreeColumnMinTotalWidthMatchesConstituents() {
        let expected = WorkspaceMetrics.leftColumnMinWidth
            + WorkspaceMetrics.centerColumnMinWidth
            + WorkspaceMetrics.rightColumnMinWidth
            + WorkspaceMetrics.resizableDividerHitWidth * 2
        XCTAssertEqual(WorkspaceMetrics.threeColumnMinTotalWidth, expected)
        XCTAssertEqual(WorkspaceMetrics.threeColumnMinTotalWidth, 668)
    }

    /// 宽度充足：三栏全开意图被完整保留。
    func testWidePlanKeepsBothSidebars() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 1024, wantLeft: true, wantRight: true)
        XCTAssertTrue(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// 低于三栏最低宽：先收右栏，且被显示栏最小宽之和不溢出容器。
    func testNarrowPlanCollapsesRightFirst() {
        // 容器只够 左+中+1分隔线（160+280+14=454），放不下右栏。
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 500, wantLeft: true, wantRight: true)
        XCTAssertTrue(plan.showLeft, "应保留左栏")
        XCTAssertFalse(plan.showRight, "空间不足应先收右栏")
        let sum = WorkspaceMetrics.leftColumnMinWidth
            + WorkspaceMetrics.centerColumnMinWidth
            + WorkspaceMetrics.resizableDividerHitWidth
        XCTAssertLessThanOrEqual(sum, 500)
    }

    /// 极窄：左右都收，仅中栏，绝不溢出。
    func testVeryNarrowPlanCollapsesBoth() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 300, wantLeft: true, wantRight: true)
        XCTAssertFalse(plan.showLeft); XCTAssertFalse(plan.showRight)
        XCTAssertLessThanOrEqual(WorkspaceMetrics.centerColumnMinWidth, 300)
    }

    /// 用户本就不想开右栏时，充足宽度也不强行展开。
    func testPlanRespectsUserIntent() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 1024, wantLeft: true, wantRight: false)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }
```

- [ ] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/WorkspaceMetricsTests`。预期：编译失败（无 `threeColumnMinTotalWidth`/`columnVisibilityPlan`/`ColumnVisibilityPlan`）。

- [ ] **Step 3: 最小实现** — `WorkspaceMetrics.swift` 在列宽常量区后加：

```swift
    /// D4：三栏全开所需最低宽 = 左min + 中min + 右min + 两分隔线（由常量算出，不写死）。
    static let threeColumnMinTotalWidth: CGFloat =
        leftColumnMinWidth + centerColumnMinWidth + rightColumnMinWidth
        + resizableDividerHitWidth * 2

    /// D4：窄窗降级决策结果——哪些侧栏应显示（中栏永远完整可见，不含在内）。
    struct ColumnVisibilityPlan: Equatable { let showLeft: Bool; let showRight: Bool }

    /// D4 纯函数：给定容器宽 + 用户展开意图，算出实际应显示哪些侧栏，
    /// 保证被显示栏最小宽之和 ≤ 容器宽、中栏永远完整。断点用物理下界，恢复用同一阈值（不抖动）。
    /// 收起顺序：先收右栏，仍不足再收左栏。
    static func columnVisibilityPlan(total: CGFloat, wantLeft: Bool, wantRight: Bool) -> ColumnVisibilityPlan {
        // 充足：尊重用户意图，原样。
        if total >= threeColumnMinTotalWidth {
            return ColumnVisibilityPlan(showLeft: wantLeft, showRight: wantRight)
        }
        // 尝试保留「左 + 中」（收右栏）：需容纳 左min + 中min + 1 分隔线。
        let leftPlusCenter = leftColumnMinWidth + centerColumnMinWidth + resizableDividerHitWidth
        if wantLeft, total >= leftPlusCenter {
            return ColumnVisibilityPlan(showLeft: true, showRight: false)
        }
        // 若用户只想要右栏（不要左栏），尝试保留「中 + 右」。
        let centerPlusRight = centerColumnMinWidth + rightColumnMinWidth + resizableDividerHitWidth
        if !wantLeft, wantRight, total >= centerPlusRight {
            return ColumnVisibilityPlan(showLeft: false, showRight: true)
        }
        // 极窄：仅中栏。
        return ColumnVisibilityPlan(showLeft: false, showRight: false)
    }
```

- [ ] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/WorkspaceMetricsTests`。预期：PASS（含既有用例不回归）。

- [ ] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift ios/CodexRemoteTests/WorkspaceMetricsTests.swift
git commit -m "feat(ipad): 增三栏最低宽常量与窄窗降级纯函数 (D4)"
```

---

### Task 6: D4 `ResizableColumns` 容器 < 阈值自动收起侧栏

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/ResizableColumns.swift`（`body` 内 `:37-59` 用降级 plan 派生实际 `leftVisible`/`rightVisible`）
- Test: 复用 Task 5 的纯函数单测（布局行为在 D9 收口 + 模拟器自验收覆盖）

**Interfaces:**
- Consumes: Task 5 的 `WorkspaceMetrics.columnVisibilityPlan(total:wantLeft:wantRight:)`；既有 props `leftVisible`/`rightVisible`（= 用户意图）、`leftWidth`/`rightWidth`（既有列宽持久化，不改）。
- Produces: 渲染派生的 `effectiveLeftVisible`/`effectiveRightVisible`——用户意图经降级 plan 过滤后的实际显隐；宽度恢复后（total ≥ 阈值）plan 还原用户意图即再展开。列宽持久化（`leftWidth`/`rightWidth`）不受降级影响（收起时不改存值）。

- [ ] **Step 1: 写失败测试（纯函数层已覆盖，本步补一条视图不溢出的结构断言，可选）** — 若采用视图级断言，新建/追加到 `RightPanelTabsLayoutTests` 同风格的一条：`ResizableColumns` 在 total=500 挂载后，中栏渲染宽 > 0 且左+中+右渲染宽之和 ≤ 500。因 `ResizableColumns` 是泛型容器、直接实例化需三个 `@ViewBuilder`，成本较高——**推荐** 本任务以 Task 5 纯函数单测为 RED/GREEN 主证据，视图层不溢出由 D9（Task 12 快照结构断言）+ 模拟器自验收（4.4）覆盖。此步记为「复用 Task 5 单测，无新测试文件」。

- [ ] **Step 2: 运行确认现状** — 运行 `WorkspaceMetricsTests` 确认纯函数绿；确认 `ResizableColumns` 当前未消费该纯函数（`:37` `dividerCount` 仅按 `leftVisible/rightVisible`，无降级）。

- [ ] **Step 3: 最小实现** — `ResizableColumns.swift` `body` 内 `GeometryReader` 里，用降级 plan 派生实际显隐：

在 `let total = proxy.size.width`（`:35`）之后加：

```swift
            // D4：窄窗降级——用户意图（leftVisible/rightVisible）经容器宽过滤成实际显隐，
            // 保证渲染宽度之和 ≤ 容器、中栏永远完整。宽度恢复到阈值以上 plan 即还原用户意图。
            let plan = WorkspaceMetrics.columnVisibilityPlan(
                total: total, wantLeft: leftVisible, wantRight: rightVisible)
            let effLeftVisible = plan.showLeft
            let effRightVisible = plan.showRight
```

把 `body` 后续所有用 `leftVisible`/`rightVisible` 的渲染判定改用 `effLeftVisible`/`effRightVisible`：
- `:37` `dividerCount` → `(effLeftVisible ? 1 : 0) + (effRightVisible ? 1 : 0)`
- `:43` `if leftVisible` → `if effLeftVisible`
- `:54` `if rightVisible` → `if effRightVisible`
- `displayedLeft`/`displayedRight`（`:78-79`）改为接收参数或改用 `effLeftVisible`/`effRightVisible`。因它们是计算属性无法读 body 局部量，改为在 body 内用局部 let：

```swift
            let dispLeft: CGFloat = effLeftVisible ? leftWidth : 0
            let dispRight: CGFloat = effRightVisible ? rightWidth : 0
```

并把 `centerColumnWidth(... left: displayedLeft, right: displayedRight ...)` 及各分隔线传参改用 `dispLeft`/`dispRight`；删除或保留旧计算属性（若他处仍引用则保留，但 body 内改用局部量以读到降级结果）。
- 动画 `.animation(..., value: leftVisible)`（`:72-73`）追加对 `effLeftVisible`/`effRightVisible` 的动画（或改为对 total 也响应），保证降级切换有过渡。
- `.onChange(of: dividerCount)`（`:69`）与 `reclamp` 继续按新的 `dividerCount` 工作。

> 关键：列宽持久化不动——降级只改「显示哪些栏」（`effLeftVisible`），不改 `leftWidth`/`rightWidth` 存值；宽度恢复后 plan 还原、列宽仍是用户上次拖定的值（spec「遵循既有列宽持久化/恢复行为」）。

- [ ] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/WorkspaceMetricsTests`；并 `xcodebuild build`（scheme CodexRemote）确认 `ResizableColumns` 改动编译通过、无遗漏引用旧 `displayedLeft/Right`。

- [ ] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/ResizableColumns.swift
git commit -m "feat(ipad): 三栏容器窄窗自动收起侧栏，渲染不横向溢出 (D4)"
```

---

### Task 7: D5 抽共享 locale 查表 helper + 静态硬编码中文改 key

**Files:**
- Create: `ios/CodexRemote/Views/Support/LocalizedBundle.swift`（抽 `ShortcutsSettingsSectionView.swift:119-133` 的正确写法）
- Modify: `ios/CodexRemote/Views/Settings/ShortcutsSettingsSectionView.swift`（`localized(_:)` 改调共享 helper，去重复实现）
- Modify: `ios/CodexRemote/Views/Workspace/FileBrowserView.swift`（`:39,46,51,127,129,131` 硬编码中文改 key）、`Views/Workspace/SideChatView.swift`（`:29,58,69,74`）、`Views/Workspace/ReviewTabView.swift`（`:32` "数据源"）、`Views/Workspace/ProgressCardBar.swift`（`:43,52` 中文）
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`（补新键 zh-Hans + en）
- Test: `ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift`（新建）

**Interfaces:**
- Produces: `enum L10n`（或 `extension EnvironmentValues`）提供 `static func string(_ key: String, locale: Locale) -> String`，实现 = 复制 `ShortcutsSettingsSectionView.swift:119-133` 三级 fallback（`locale.identifier` 的 lproj → 语言码 lproj → `Bundle.main`）。供动态标签（Task 8 的 tab label / 审查模式名）与需运行期解析的场景复用。
- Consumes: `Localizable.xcstrings` 键。静态 `Text("key")` 类字面量 **不** 经此 helper（它们已跟随注入 locale），只把硬编码中文字面量改成 key。

- [x] **Step 1: 写失败测试** — 新建 `LocalizationFollowsInjectedLocaleTests.swift`：断言共享 helper 在注入 en 时返回英文、注入 zh-Hans 时返回中文；断言此前硬编码的键存在于两种语言表。

```swift
import XCTest
@testable import CodexRemote

/// D5：面向用户文案跟随注入 locale。共享 helper 按 locale 查对应 .lproj 表，
/// 切 en 得英文、切 zh-Hans 得中文，均非 key 本身（键存在）。
final class LocalizationFollowsInjectedLocaleTests: XCTestCase {

    /// 本任务新增/迁移的键，两种语言都必须可解析（解析失败会回落成 key 本身）。
    private let keys = [
        "review.source",            // 原 "数据源"
        "fileBrowser.empty",        // 原 "无选中会话，暂无可浏览目录"
        "fileBrowser.title",        // 原 "文件"
        "fileBrowser.refresh",      // 原 "刷新"
        "fileBrowser.tooLarge",     // 原 "文件过大，不支持预览"
        "fileBrowser.binary",       // 原 "二进制文件，不支持预览"
        "fileBrowser.selectFile",   // 原 "选择文件查看"
        "sideChat.start",           // 原 "开始侧聊"
        "sideChat.close",           // 原 "关闭侧聊"
        "sideChat.noMainThread",    // 原 "无选中主对话…"
        "sideChat.pickToStart",     // 原 "点「开始侧聊」…"
        "review.mode.turn",         // 原 "本轮"
        "review.mode.full",         // 原 "全量"
    ]

    func test_sharedHelper_returnsInjectedLanguage() {
        let en = Locale(identifier: "en")
        let zh = Locale(identifier: "zh-Hans")
        for key in keys {
            let e = L10n.string(key, locale: en)
            let z = L10n.string(key, locale: zh)
            XCTAssertNotEqual(e, key, "en 缺键 \(key)")
            XCTAssertNotEqual(z, key, "zh 缺键 \(key)")
            // en 结果不含 CJK（无中英混排残留）。
            XCTAssertFalse(e.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                           "en 文案含中文残留：\(key)=\(e)")
        }
    }
}
```

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`。预期：编译失败（无 `L10n`）+ 键缺失。

- [x] **Step 3: 最小实现**

创建 `LocalizedBundle.swift`：

```swift
import Foundation

/// D5：跟随注入 locale 的本地化查表入口。
/// 关键：不用 `String(localized:)`——它按系统语言选表、忽略应用内注入 locale（LocaleManager）。
/// 复用 ShortcutsSettingsSectionView 已验证的三级 fallback：identifier lproj → 语言码 lproj → 主 bundle。
enum L10n {
    static func string(_ key: String, locale: Locale) -> String {
        if let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        if let code = locale.language.languageCode?.identifier,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
```

改 `ShortcutsSettingsSectionView.swift` 的 `private func localized(_:)`（`:122-134`）为薄委托（去重复实现，保留方法名不动调用点）：

```swift
    private func localized(_ key: String) -> String { L10n.string(key, locale: locale) }
```

改静态硬编码中文为 key（这些是 `Text`/`Button`/`Picker` 的 `LocalizedStringKey` 参数，天然跟随注入 locale，直接换 key 即可）：
- `ReviewTabView.swift:32` `Picker("数据源", ...)` → `Picker("review.source", ...)`
- `FileBrowserView.swift`：`Text("无选中会话，暂无可浏览目录")` → `Text("fileBrowser.empty")`；`Text("文件")` → `Text("fileBrowser.title")`；`.accessibilityLabel(Text("刷新"))` → `Text("fileBrowser.refresh")`；`placeholder("文件过大，不支持预览")` → `placeholder("fileBrowser.tooLarge")`（确认 `placeholder(_:)` 形参为 `LocalizedStringKey`；若为 `String`，改用 `String(localized:)` 不合规——则包一层 `Text` 或让 `placeholder` 收 `LocalizedStringKey`。查 `FileBrowserView.swift` `placeholder` 定义确认类型后决定）；`placeholder("二进制文件，不支持预览")` → `"fileBrowser.binary"`；`placeholder("选择文件查看")` → `"fileBrowser.selectFile"`
- `SideChatView.swift`：`Label("开始侧聊", ...)` → `Label("sideChat.start", ...)`；`.accessibilityLabel("关闭侧聊")` → `"sideChat.close"`；`emptyState(text: "无选中主对话…")` → 因 `emptyState(text:)` 形参当前是 `String`，改签名为 `LocalizedStringKey` 或传 `String(localized:)`……**但 `String(localized:)` 不跟随注入 locale**。故把 `emptyState(_ text: String)` 改为 `emptyState(_ key: LocalizedStringKey)`，内部 `Text(key)`，调用传 `"sideChat.noMainThread"` / `"sideChat.pickToStart"`。
- `ProgressCardBar.swift:43,52` 拼接中文（`"第 "`, `" 步"`, `" 个文件已更改"`）→ 改为带占位的本地化键，如 `Text("progress.step \(progress.completed)/\(progress.total)")`（xcstrings 里 en/zh 各给格式串），`Text("progress.filesChanged \(diff.changedFiles)")`。

**动态标签（`ReviewSourceMode.label`，`ReviewPanelTypes.swift:19`）** 在 Task 8 处理（它不是 `View`，拿不到 `@Environment(\.locale)`，须走 helper 或改由视图注入）——本任务先把 `ReviewPanelTypes.swift:19` 的 `"本轮"/"全量"` 键 `review.mode.turn`/`review.mode.full` **加进 xcstrings**，`label` 的改造留到 Task 8。

在 `Localizable.xcstrings` 补全上述所有新键的 en + zh-Hans 值（照文件既有 JSON 结构，每键一个 `localizations.en.stringUnit` + `localizations.zh-Hans.stringUnit`）。含 `progress.step %@`/`progress.filesChanged %@` 格式键。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`；并 `xcodebuild build` 确认视图改动编译通过。预期：PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Support/LocalizedBundle.swift ios/CodexRemote/Views/Settings/ShortcutsSettingsSectionView.swift ios/CodexRemote/Views/Workspace/FileBrowserView.swift ios/CodexRemote/Views/Workspace/SideChatView.swift ios/CodexRemote/Views/Workspace/ReviewTabView.swift ios/CodexRemote/Views/Workspace/ProgressCardBar.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift
git commit -m "feat(ipad): 抽共享 locale 查表 helper，静态硬编码中文改本地化键 (D5)"
```

---

### Task 8: D5 动态标签跟随注入 locale（右栏 tab label + 审查模式名）

**Files:**
- Modify: `ios/CodexRemote/Protocol/ReviewPanelTypes.swift`（`ReviewSourceMode.label` 去硬编码/去依赖系统语言）
- Modify: `ios/CodexRemote/Views/Workspace/ReviewTabView.swift`（`ForEach(...) { Text(m.label) }` 改传注入 locale）
- Modify: `ios/CodexRemote/Views/Workspace/RightPanelContainerView.swift`（`RightPanelTab.label` 用 `String(localized:)` → 改跟随注入 locale）
- Test: `ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift`（扩充动态标签断言）

**Interfaces:**
- Consumes: Task 7 的 `L10n.string(_:locale:)`。
- Produces:
  - `ReviewSourceMode.label(locale:)` — 由无参 `label` 改为 `func label(locale: Locale) -> String`，内部 `L10n.string(self == .turn ? "review.mode.turn" : "review.mode.full", locale: locale)`。
  - `RightPanelTab.label(locale:)` — 同理，`String(localized: "rightPanel.tab.review")` 改 `L10n.string("rightPanel.tab.review", locale:)`。
  - 两处调用点从 `@Environment(\.locale)` 取 locale 传入。

- [x] **Step 1: 写失败测试** — 在 `LocalizationFollowsInjectedLocaleTests.swift` 追加：

```swift
    /// 动态标签（审查模式名、右栏 tab 名）按注入 locale 解析，en 无中文残留。
    func test_dynamicLabels_followInjectedLocale() {
        let en = Locale(identifier: "en")
        for mode in ReviewSourceMode.allCases {
            let s = mode.label(locale: en)
            XCTAssertFalse(s.isEmpty)
            XCTAssertFalse(s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                           "审查模式名 en 含中文残留：\(s)")
        }
        for tab in RightPanelTab.allCases {
            let s = tab.label(locale: en)
            XCTAssertFalse(s.isEmpty)
            XCTAssertFalse(s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        }
    }
```

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`。预期：编译失败（`label` 无 `locale:` 形参）。

- [x] **Step 3: 最小实现**
- `ReviewPanelTypes.swift:16-20`：把 `var label: String { self == .turn ? "本轮" : "全量" }` 改为 `func label(locale: Locale) -> String { L10n.string(self == .turn ? "review.mode.turn" : "review.mode.full", locale: locale) }`（保留 `id`）。`ReviewPanelTypes.swift` 需 `import Foundation`（已有）；`L10n` 同 target 可见。同步改 `resolve(...)` 里 `label: mode.label`（`:26-27`）——它用 label 作数据源标签，改传 locale 会污染纯数据结构。**取舍**：`ReviewDiffSource.label` 是展示用字符串，改 `resolve(mode:turnDiff:fullDiff:locale:)` 接 locale，或让 `label` 存 key 字符串、由视图解析。最小改动：给 `resolve` 加 `locale: Locale` 形参传入 `mode.label(locale:)`；调用点（搜索 `ReviewDiffSource.resolve`）补传 `@Environment(\.locale)`。
- `ReviewTabView.swift:32-34`：`Text(m.label)` → `Text(m.label(locale: locale))`，并在该视图加 `@Environment(\.locale) private var locale`（若无）。
- `RightPanelContainerView.swift:4-14`：`RightPanelTab.label` 由计算属性改 `func label(locale:)`（内部 `L10n.string`）；`tabBar`（Task 4 已改）里 `Text(tab.label)` → `Text(tab.label(locale: locale))`（容器已有 `@Environment(\.locale) private var locale`，`:32`）。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests -only-testing:CodexRemoteTests/RightPanelTabsLayoutTests`；`xcodebuild build`。预期：PASS 且既有引用编译通过。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Protocol/ReviewPanelTypes.swift ios/CodexRemote/Views/Workspace/ReviewTabView.swift ios/CodexRemote/Views/Workspace/RightPanelContainerView.swift ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift
git commit -m "feat(ipad): 动态标签（tab/审查模式名）跟随注入 locale (D5)"
```

---

### Task 9: D6 删机器二次确认 + 管理菜单连接态互斥

**Files:**
- Modify: `ios/CodexRemote/Views/TabBarView.swift`（`:68-80` 管理菜单 + 新增 confirmationDialog）
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`（补确认弹窗键）
- Test: `ios/CodexRemoteTests/TabBarViewTests.swift`（扩充）

**Interfaces:**
- Consumes: `SessionsManager.canConnect(id:)`（`:62`，`shouldAutoConnect ?? true`）、`removeMachine(id:)`（`:76`）、`connectMachine(id:)`（`:56`）、`disconnect(id:)`（`:95`）。
- Produces: `TabBarView` 新增 `@State private var removeTarget: UUID?`（非空即弹 `confirmationDialog`，`role: .destructive` 的确认按钮才调 `removeMachine`）；管理菜单把「连接」「断开」由「连接条件渲染 + 断开无条件渲染」（现状 `:69-72` 两者可同现）改为 `if canConnect { 连接 } else { 断开 }` 互斥。

- [x] **Step 1: 写失败测试** — `TabBarViewTests.swift` 追加：断言 `canConnect` 决定互斥（逻辑层）、移除走确认（结构层挂载不崩溃 + 逻辑：未确认不删）。因 `confirmationDialog` 交互难在单测点按，核心断言落在 `SessionsManager` 未连接态 `canConnect == true`、已就绪态 `canConnect == false` 的互斥判定 + 「直接调 removeMachine 之外必须经确认」的接线（用 `removeTarget` 状态存在性 + 手工走读）。

```swift
    /// D6：连接互斥判定——未连接态可连（应只显示「连接」），已就绪态不可连（应只显示「断开」）。
    func test_canConnect_isMutuallyExclusiveByState() {
        let sessions = mgr(machines: 1)
        let id = sessions.machineStore.machines[0].id
        // 初始（未连接）：canConnect == true → 菜单应渲染「连接」而非「断开」。
        XCTAssertTrue(sessions.canConnect(id: id), "未连接态应可连（互斥显示连接）")
    }

    /// D6：移除机器不应由单次点击直接执行——TabBarView 持有 removeTarget 确认态。
    /// 结构断言：视图挂载渲染不崩溃（confirmationDialog 接线成立）。
    func test_tabBar_mountsWithRemoveConfirmation() {
        let sessions = mgr(machines: 2)
        let hc = UIHostingController(rootView: TabBarView().environment(sessions))
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        XCTAssertEqual(sessions.machineStore.machines.count, 2)
    }
```

> 已就绪态 `canConnect == false` 的断言需驱动一条连接到 ready，成本高；本任务以「未连接可连」+ 互斥渲染的代码结构（`if/else`）+ 模拟器自验收（4.4）覆盖已连接态。

- [x] **Step 2: 运行确认失败/现状** — `xcodebuild test -only-testing:CodexRemoteTests/TabBarViewTests`。预期：新断言可编译并 PASS（`canConnect` 已存在），但 `test_tabBar_mountsWithRemoveConfirmation` 只验挂载；真正 RED 是「菜单同现连接+断开」与「无确认直删」的结构——通过下一步实现改正并保持测试绿。

- [x] **Step 3: 最小实现** — 改 `TabBarView.swift`：

加状态字段（`:10` 附近）：

```swift
    /// 待移除确认的机器 id（非空即弹二次确认 dialog）。
    @State private var removeTarget: UUID?
```

管理菜单 `:68-80` 改互斥 + 移除走确认：

```swift
            Menu {
                // 连接 / 断开互斥：由单一连接态推导，不同现两者（D6）。
                if sessions.canConnect(id: m.id) {
                    Button("tab.connect", systemImage: "bolt.horizontal") { sessions.connectMachine(id: m.id) }
                } else {
                    Button("tab.disconnect", systemImage: "wifi.slash") { sessions.disconnect(id: m.id) }
                }
                Button("tab.rename", systemImage: "pencil") { beginRename(m) }
                Button("tab.remove", systemImage: "trash", role: .destructive) { removeTarget = m.id }
            } label: { ... 保持不变 ... }
```

在 `body` 的 `.alert(...)` 链后追加移除确认 dialog：

```swift
        .confirmationDialog("tab.remove.confirm.title",
                            isPresented: removeConfirmBinding,
                            titleVisibility: .visible) {
            Button("tab.remove.confirm.action", role: .destructive) {
                if let id = removeTarget { sessions.removeMachine(id: id) }
                removeTarget = nil
            }
            Button("common.cancel", role: .cancel) { removeTarget = nil }
        } message: {
            Text("tab.remove.confirm.message")
        }
```

加桥接（照 `renameAlertBinding` `:40-43` 范式）：

```swift
    private var removeConfirmBinding: Binding<Bool> {
        Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })
    }
```

在 `Localizable.xcstrings` 补 `tab.remove.confirm.title` / `tab.remove.confirm.message` / `tab.remove.confirm.action` 的 en + zh。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/TabBarViewTests`；`xcodebuild build`。预期：PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/TabBarView.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/TabBarViewTests.swift
git commit -m "feat(ipad): 移除机器加二次确认，管理菜单连接/断开互斥 (D6)"
```

---

### Task 10: D7 触控命中框 + 语义标签 + 会话行按钮语义

**Files:**
- Modify: `ios/CodexRemote/Views/ComposerView.swift`（`:77-120` 图片/模型/停止/发送按钮 44pt 命中框 + accessibilityLabel）
- Modify: `ios/CodexRemote/Views/SidebarView.swift`（`:136-140` 会话行 `onTapGesture` → `Button`）
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`（补 accessibility label 键）
- Test: `ios/CodexRemoteTests/TouchAccessibilityTests.swift`（新建）

**Interfaces:**
- Produces: ComposerView 四类图标按钮统一 `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())` + `.accessibilityLabel(Text("<key>"))`；SidebarView `threadRow` 的 `.onTapGesture`（`:137`）改为整行 `Button`（获 button trait + 键盘激活），保留既有视觉（左缘橙条 + 橙标题），`contextMenu`（`:141`）保留。
- Consumes: 无跨任务依赖。

- [x] **Step 1: 写失败测试** — 新建 `TouchAccessibilityTests.swift`。SwiftUI 无障碍属性单测受限，采用「挂载 + 遍历命中区尺寸 ≥ 44」结构断言（照 Task 4 的 `hittableRects` 范式）+ 存在 accessibilityLabel（经 hosting 的 `accessibilityElements`/`accessibilityLabel` 读取，若不稳定则退化为「键存在于 xcstrings」+ 手工走读）。

```swift
import XCTest
import SwiftUI
@testable import CodexRemote

/// D7：核心图标按钮命中框 ≥44pt；会话行具备 button 语义。
@MainActor
final class TouchAccessibilityTests: XCTestCase {

    /// ComposerView 的图标按钮命中区不小于 44×44pt。
    func test_composerIconButtons_meetMinHitTarget() {
        let store = ConversationStore(rpc: nil, threadId: "t")   // 若 init 需非空 rpc，用 MockTransport 造 JSONRPCClient
        let view = ComposerView(store: store).environment(EnvironmentStore())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 400, height: 120)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc; window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()

        let controls = Self.tappableRects(in: hc.view).filter { $0.width > 0 }
        XCTAssertFalse(controls.isEmpty, "应能找到图标按钮命中区")
        for r in controls {
            XCTAssertGreaterThanOrEqual(r.height, 44, "命中区高应 ≥44pt：\(r)")
            XCTAssertGreaterThanOrEqual(r.width, 44, "命中区宽应 ≥44pt：\(r)")
        }
    }

    private static func tappableRects(in root: UIView) -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ v: UIView) {
            if (v is UIControl) || (v.gestureRecognizers?.isEmpty == false), v.isUserInteractionEnabled {
                out.append(v.convert(v.bounds, to: root))
            }
            v.subviews.forEach(walk)
        }
        walk(root); return out
    }
}
```

> `ConversationStore(rpc:threadId:)` 若不接受 nil rpc，则先用 `JSONRPCClient(transport: MockTransport())` 造一个再传。会话行 button 语义的断言以 SidebarView 挂载不崩溃 + 手工走读 `Button` 替换为准（VoiceOver button trait 由真机/模拟器自验收 4.4 覆盖）。

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/TouchAccessibilityTests`。预期：FAIL（当前 `plus.circle`/`slider.horizontal.3` 等按钮无 44pt 命中框，高 < 44）。

- [x] **Step 3: 最小实现**

`ComposerView.swift`：给四个图标按钮统一命中框 + label。抽一个私有 modifier 复用：

```swift
    /// D7：图标按钮统一 ≥44pt 命中框 + 语义标签。
    private func iconButtonFrame() -> some ViewModifier { IconHitTarget() }
```

或直接在每个按钮 label 上追加 `.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())`，并给按钮加 `.accessibilityLabel`：
- PhotosPicker（`:77-79`）：label 内 `Image` 后加 `.frame(minWidth:44,minHeight:44).contentShape(Rectangle())`；PhotosPicker 外 `.accessibilityLabel(Text("composer.a11y.pickImage"))`
- 模型按钮（`:83-86`）：同上 + `.accessibilityLabel(Text("composer.a11y.model"))`
- 停止按钮（`:97-101`）：`.frame(minWidth:44,minHeight:44)` + `.accessibilityLabel(Text("composer.a11y.stop"))`
- 发送按钮（`:114-119`）：`.frame(minWidth:44,minHeight:44)` + `.accessibilityLabel(Text("composer.a11y.send"))`
- steer/enqueue Menu 触发钮（`:102-111`）可一并补 label（`composer.a11y.more`）。

`SidebarView.swift` `threadRow`（`:98-154`）：把 `.contentShape(Rectangle()).onTapGesture {...}`（`:136-140`）替换为整行 `Button`。方案：把 `HStack {...}`（行内容）包成 `Button { selectedThreadId = ...; projects.markViewed(...) } label: { <原 HStack> }` + `.buttonStyle(.plain)`（保留视觉），`contextMenu`（`:141-153`）挂在 Button 上：

```swift
        Button {
            selectedThreadId = thread.id
            projects.markViewed(threadId: thread.id, updatedAt: thread.updatedAt)
        } label: {
            HStack(spacing: 8) { ... 原行内容不变 ... }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ... 原 fork 菜单不变 ... }
```

在 `Localizable.xcstrings` 补 `composer.a11y.{pickImage,model,stop,send,more}` 的 en + zh。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/TouchAccessibilityTests`；`xcodebuild build`。预期：PASS（命中区 ≥44）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/ComposerView.swift ios/CodexRemote/Views/SidebarView.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/TouchAccessibilityTests.swift
git commit -m "feat(ipad): 图标按钮 44pt 命中框+语义标签，会话行改按钮语义 (D7)"
```

---

## 批3 — P3 + 收口（D8 + D9）

### Task 11: D8 空态引导 + 对话滚动位置感知

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（`:228-234` `content` 未选会话空态）
- Modify: `ios/CodexRemote/Views/ConversationView.swift`（`:20-47` ScrollView + 近底判定 + 「新消息」浮标；`:41-46` onChange gate；`:133-141` scrollToBottom）
- Test: `ios/CodexRemoteTests/ConversationScrollAnchorTests.swift`（新建）

**Interfaces:**
- Produces:
  - `RootSplitView.content` 未选会话分支由 `Color(.systemBackground)`（`:232`）改为渲染 `split.selectConversation` 引导空态（`ContentUnavailableView` 或等价，复用既有键；`SidebarView.swift:38` 已示范 `ContentUnavailableView`）。
  - `ConversationView` 增近底判定纯状态：`@State private var isNearBottom = true`、`@State private var hasNewBelow = false`；仅 `isNearBottom` 时新内容 `onChange` 自动滚；否则不滚 + 显「新消息」浮标（`safeAreaInset` 或 overlay），点按 `scrollToBottom` 并复位 `hasNewBelow=false`。近底判定用 `GeometryReader` 底部哨兵可见性（纯 UI、事件驱动，无轮询/定时器）。
- Consumes: `split.selectConversation` 键（`Localizable.xcstrings:4052`，已存在）。

- [x] **Step 1: 写失败测试** — 滚动位置感知的核心是 UI 手势，难在纯单测驱动。把可判定逻辑抽成纯函数并单测它；视图行为交模拟器自验收（4.4）。

新建 `ConversationScrollAnchorTests.swift`，测「是否自动滚」的决策纯函数：

```swift
import XCTest
@testable import CodexRemote

/// D8：滚动位置感知决策——仅近底时新内容自动滚；远离底部时不滚且提示「新消息」。
final class ConversationScrollAnchorTests: XCTestCase {

    func test_nearBottom_autoScrollsOnNewContent() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: false))
    }

    /// 远离底部且有新内容到达 → 应显示「新消息」入口。
    func test_awayFromBottom_showsNewMessagesAffordance() {
        XCTAssertTrue(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: false, contentDidGrow: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: true, contentDidGrow: true))
        XCTAssertFalse(ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: false, contentDidGrow: false))
    }

    /// 近底阈值判定：offset 距底 ≤ 阈值算近底。
    func test_nearBottomThreshold() {
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 40, threshold: 120))
        XCTAssertFalse(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 400, threshold: 120))
    }
}
```

- [x] **Step 2: 运行确认失败** — `xcodebuild test -only-testing:CodexRemoteTests/ConversationScrollAnchorTests`。预期：编译失败（无 `ScrollAnchorPolicy`）。

- [x] **Step 3: 最小实现**

在 `ConversationView.swift`（文件内或同目录新建小文件）加纯策略：

```swift
/// D8：对话滚动位置感知的纯决策（可单测，无 UI 依赖）。
enum ScrollAnchorPolicy {
    /// 是否近底：距底距离 ≤ 阈值。
    static func isNearBottom(distanceToBottom: CGFloat, threshold: CGFloat = 120) -> Bool {
        distanceToBottom <= threshold
    }
    /// 新内容到达时是否自动滚到底：仅近底时。
    static func shouldAutoScroll(isNearBottom: Bool) -> Bool { isNearBottom }
    /// 是否显示「新消息」入口：远离底部且内容增长时。
    static func shouldShowNewBelow(isNearBottom: Bool, contentDidGrow: Bool) -> Bool {
        !isNearBottom && contentDidGrow
    }
}
```

`ConversationView` 接线（改 `:20-47` + `:41-46` + 加浮标）：
- 加 `@State private var isNearBottom = true` / `@State private var showNewBelow = false`。
- 在 `LazyVStack` 末尾加零高哨兵 + `GeometryReader` 或用 `ScrollView` 的 `onScrollGeometryChange`（iOS 18+；确认部署目标；若低于 18，用底部哨兵 `.onAppear/.onDisappear` 切 `isNearBottom`——纯事件驱动，无定时器）。最小实现用底部哨兵：

```swift
                    // 底部哨兵：进入/离开可视区切换近底态（事件驱动，无轮询）。
                    Color.clear.frame(height: 1).id(Self.bottomSentinelID)
                        .onAppear { isNearBottom = true; showNewBelow = false }
                        .onDisappear { isNearBottom = false }
```

- `onChange(of: items.count)`（`:41`）改：

```swift
            .onChange(of: store?.state.items.count) { _, _ in
                if ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: isNearBottom) {
                    scrollToBottom(proxy)
                } else {
                    showNewBelow = true
                }
            }
```

- 加「新消息」浮标（overlay 底部居中，仅 `showNewBelow` 时）：

```swift
            .overlay(alignment: .bottom) {
                if showNewBelow {
                    Button {
                        withAnimation { scrollToBottom(proxy); showNewBelow = false }
                    } label: {
                        Label("conv.newMessages", systemImage: "arrow.down.circle.fill")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .accessibilityLabel(Text("conv.newMessages"))
                }
            }
```

`RootSplitView.swift` `content`（`:228-234`）未选分支：

```swift
    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(threadId: id).id(id)
        } else {
            ContentUnavailableView("split.selectConversation", systemImage: "bubble.left.and.bubble.right")
        }
    }
```

在 `Localizable.xcstrings` 补 `conv.newMessages` 的 en + zh（`split.selectConversation` 已存在）。加 `private static let bottomSentinelID = "__bottom_sentinel__"`。

> 能耗守则：近底态切换纯靠哨兵 `onAppear/onDisappear`（滚动事件驱动），无 `Timer`/无轮询。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/ConversationScrollAnchorTests`；`xcodebuild build`。预期：PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/ConversationView.swift ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/ConversationScrollAnchorTests.swift
git commit -m "feat(ipad): 未选会话引导空态 + 对话滚动位置感知（新消息浮标）(D8)"
```

---

### Task 12: D9 升级 `OrientationSnapshotTests` 右栏结构断言 + 收口检查

**Files:**
- Modify: `ios/CodexRemoteTests/OrientationSnapshotTests.swift:254-268`（`test_right_panel_snapshot` 由「PNG 非空」升级为 tab 可见性/不溢出结构断言，或改指向 Task 4 的 `RightPanelTabsLayoutTests`）

**Interfaces:**
- Consumes: Task 4 的 `RightPanelTabsLayoutTests.hittableRects`（若跨类复用，抽成 `OrientationSnapshotTests` 可见的测试工具，或在本类内重复最小实现——测试代码可局部重复以保独立可读）。
- Produces: `test_right_panel_snapshot` 增加结构断言：右栏在 320pt 下三 tab 命中区计数 ≥3 且无命中区 `maxX > 容器宽`（不横向裁剪/溢出），不再只 `snapshot(... PNG 非空)`。

- [x] **Step 1: 写失败测试** — 在 `OrientationSnapshotTests.swift` 的 `test_right_panel_snapshot`（`:255-268`）里，`snapshot(...)` 之后追加结构断言（先加断言、此时若 Task 4 已合入则应已绿；若单独看是 RED 需求为「原测试无任何结构断言」）：

```swift
        // D9：不再止于「PNG 非空」——断言窄宽下 tab 命中区完整、不横向溢出。
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc; window.makeKeyAndVisible()
        hc.view.setNeedsLayout(); hc.view.layoutIfNeeded()
        var rects: [CGRect] = []
        func walk(_ v: UIView) {
            if v.isUserInteractionEnabled,
               (v is UIControl) || (v.gestureRecognizers?.isEmpty == false) {
                rects.append(v.convert(v.bounds, to: hc.view))
            }
            v.subviews.forEach(walk)
        }
        walk(hc.view)
        let hittable = rects.filter { $0.width > 0 && $0.height > 0 }
        XCTAssertGreaterThanOrEqual(hittable.count, 4, "右栏应有 3 tab + 全屏入口 ≥4 命中区")
        for r in hittable { XCTAssertLessThanOrEqual(r.maxX, 320.5, "右栏命中区溢出：\(r)") }
```

- [x] **Step 2: 运行确认** — `xcodebuild test -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_right_panel_snapshot`。若 Task 4 已实现则 PASS；若在无 Task 4 修复的历史点跑则 FAIL（证明结构断言有效捕获 P1#2 逃逸根因）。

- [x] **Step 3: 收口检查（无新增实现，纯核对）** — 逐条核对：
  - 所有新增/改动路径都有断言级测试（SideChatIsolation / ConnectionStore 多订阅 / RightPanelTabsLayout / WorkspaceMetrics 降级 / LocalizationFollowsInjectedLocale / TabBarView 互斥 / TouchAccessibility / ConversationScrollAnchor / OrientationSnapshot 结构）。
  - `grep -rn 'PNG 非空' ios/CodexRemoteTests` 确认无「仅 PNG 非空、无其它断言」的空快照残留（有则补结构断言或移除）。
  - `grep -rnP '"[^"]*[\x{4e00}-\x{9fff}]' ios/CodexRemote/Views ios/CodexRemote/Protocol/ReviewPanelTypes.swift | grep -vP '///|:\s*//'` 确认无遗漏的面向用户硬编码中文字面量。

- [x] **Step 4: 运行确认通过** — `xcodebuild test -only-testing:CodexRemoteTests/OrientationSnapshotTests`。预期：PASS。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemoteTests/OrientationSnapshotTests.swift
git commit -m "test(ipad): 右栏快照升级为 tab 可见性/不溢出结构断言，收口测试盲区 (D9)"
```

---

## 4. 验证（全量收口，非单独 commit，除非需修）

- [ ] **4.1 全量测试全绿** — 运行完整 `xcodebuild test`（scheme CodexRemote，iPad 模拟器）。预期：含全部新增单测在内全绿；任何回归就地修复并归入相关任务提交。
- [ ] **4.2 UI 三基线逐项覆盖** — 对每个碰 UI 的任务（Task 1/4/6/7/8/9/10/11），在模拟器分别验 **横屏 + 竖屏** 与 **手势 / 软键盘 / 外接键盘**：
  - D3 右栏 tab：横竖屏 + 320pt 窄列下三 tab 触控/指针/外接键盘聚焦均可切换。
  - D4 三栏降级：竖屏、Stage Manager 窄窗、分屏各验一遍不横向溢出、中栏完整。
  - D7：外接键盘 Tab 键能聚焦会话行、回车/空格激活；软键盘弹出时 composer 命中框不被遮挡。
- [ ] **4.3 能耗核对** — 代码走读确认 D8 滚动感知（哨兵 `onAppear/onDisappear`）、D4 降级（纯函数派生）均无 `Timer`/`Task.sleep` 轮询/新增常驻定时器；`grep -rn 'Timer\|repeatForever\|Task.sleep' ios/CodexRemote/Views/ConversationView.swift ios/CodexRemote/Views/Workspace/ResizableColumns.swift` 复核。
- [ ] **4.4 模拟器自验收（`self-verify-on-simulator`）** — 8 项发现逐条复现→修复对照：①侧聊开关不覆盖审查面板 ②重连主对话+侧聊都恢复 ③320pt 三 tab 可达 ④窄窗不溢出 ⑤切英文无中文残留 ⑥移除机器有二次确认+菜单互斥 ⑦图标按钮 44pt+VoiceOver 朗读+会话行键盘激活 ⑧未选会话有引导+上翻不打断+新消息浮标。
- [ ] **4.5 真机验收沉淀** — 把受设备配额限制的项（VoiceOver 实读、指针悬停、真实分屏/Stage Manager）追加到 `docs/真机验收清单.md`（照既有章节格式）。

---

## 自检对照（spec 覆盖 / 占位符 / 类型一致）

**spec 覆盖：** ipad-side-chat→Task1/3；ipad-reconnect-resync→Task2/3；ipad-right-panel-tabs→Task4；ipad-multi-connection（窄窗降级 + 移除确认/菜单互斥）→Task5/6/9；ipad-localization→Task7/8；ipad-touch-accessibility→Task10；ipad-conversation-ux（空态 + 滚动感知）→Task11；测试盲区（D9）→Task4/12。7 个 delta capability 全覆盖。

**类型一致：** `bindsWorkspaceState: Bool`（Task1↔3）、`addResumeHandler(_:)->ResumeToken`/`removeResumeHandler(_:)`/`ResumeToken`（Task2↔3）、`WorkspaceMetrics.columnVisibilityPlan(total:wantLeft:wantRight:)->ColumnVisibilityPlan` 与 `threeColumnMinTotalWidth`（Task5↔6）、`L10n.string(_:locale:)`（Task7↔8↔10）、`ReviewSourceMode.label(locale:)`/`RightPanelTab.label(locale:)`（Task8）、`ScrollAnchorPolicy.{isNearBottom,shouldAutoScroll,shouldShowNewBelow}`（Task11）、`removeTarget`/`removeConfirmBinding`（Task9）—— 各处签名一致。

**能耗/安全/UI 三基线：** 已在全局约束与 4.2/4.3 固化；D8/D4 明确纯事件驱动无轮询；全程不碰 relay/E2E/传输/Keychain。
