---
change: workspace-ui-review-fixes-2
design-doc: docs/superpowers/specs/2026-08-05-workspace-ui-review-fixes-2-design.md
base-ref: 6a558cf364756a23d29707cf0628179b2f5110d2
---

# workspace-ui-review-fixes-2 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施。每步用 checkbox（`- [ ]`）跟踪。
> 设计 RFC：`docs/superpowers/specs/2026-08-05-workspace-ui-review-fixes-2-design.md`（D1–D9）。验收场景（canonical）：`openspec/changes/workspace-ui-review-fixes-2/specs/*/spec.md`。

**Goal（目标）：** 逐条闭合第二轮外部 UI review 10 处发现（#2–#10），每处以「生产路径可见行为」验收（守首轮教训 R5：孤立函数测过 ≠ 生产接入）。

**Architecture（做法）：** 纯 SwiftUI + `@Observable` store 的既有 iPad 客户端。可单测的逻辑（缓存失效、窄窗档位、近底阈值、注入 locale 文案）走 XCTest；接线/观感（跳转、自动滚、可读性、反馈）走模拟器 + 真机横竖屏验收。全部改动仅触 UI/展示层。

**Tech Stack：** Swift 5 / SwiftUI（部署目标 iOS 17.0）、XCTest、xcodegen 生成工程、`xcodebuild` 跑模拟器 `iPad-Test`。

## Global Constraints（每个任务的隐含要求，逐条 verbatim）

- **安全面零触碰**：不改 relay / E2E / transport / Keychain / security 逻辑符号。本地化一个展示串 **不算**「碰 relay」；`.failed(String)` 枚举契约不变。开发者日志 `connLog.*` 中文串不动。
- **energy-awareness**：不新增轮询 / 周期定时器。#7/#9/#10 必须事件驱动（layout/geometry/state-change 驱动）；#9 横幅自动收起允许一次性 `Task.sleep`（有先例 `ConversationView.swift:156`，单次挂起无周期唤醒）。
- **ui-adaptation-baseline**：所有碰 UI 的修复（#3/#4/#6/#7/#8/#9/#10）必须横屏 + 竖屏各验一遍，软键盘/外接键盘不遮挡、可交互。
- **iOS 17.0 部署目标**：禁用 iOS-18-only API（如 `onScrollGeometryChange`）。#10 用 `GeometryReader` + `PreferenceKey` 测 `distanceToBottom`，喂 `ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:120)`。
- **首轮教训**：验证「生产已接线的真实行为」，不止孤立函数单测通过。

## 构建 / 测试命令（所有任务复用）

```bash
# 纯构建 guard（改任何 Swift 后先跑）：
bash ios/comet-build-check.sh

# 跑某个测试类（先 xcodegen，再 xcodebuild test）：
cd ios && xcodegen generate >/dev/null && cd - >/dev/null
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath ios/DerivedData \
  -only-testing:CodexRemoteTests/<测试类名> -quiet
```

> 说明：本仓库测试用例位于 `ios/CodexRemoteTests/`。UI-only（无法单测）的任务以「模拟器 + 真机横竖屏验收」为终检，见各任务验证步。

---

## Task 1（#2 · tasks 1.1）：全量 diff 缓存按 mode+cwd 失效

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/ReviewTabView.swift`
- Test: `ios/CodexRemoteTests/ReviewFullDiffCacheTests.swift`（新建）

**Interfaces:**
- Consumes: `ActiveConversationHolder.fetchFullDiff: ((_ cwd: String) async -> String?)?`（`RootSplitView.swift:14`）、`ReviewSourceMode`（`.turn`/`.full`）。
- Produces: 静态纯函数 `ReviewTabView.shouldRefetchFullDiff(mode:cachedCwd:currentCwd:) -> Bool`（Task 无其它下游依赖）。

- [x] **Step 1: 写失败测试**

新建 `ios/CodexRemoteTests/ReviewFullDiffCacheTests.swift`：

```swift
import XCTest
@testable import CodexRemote

/// #2：全量 diff 缓存以 mode+cwd 复合键失效——切工作区（cwd 变）必重取，同 cwd 不重复取。
final class ReviewFullDiffCacheTests: XCTestCase {
    func test_switchCwd_refetches() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: "/A", currentCwd: "/B"))
    }
    func test_sameCwd_noRefetch() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: "/A", currentCwd: "/A"))
    }
    func test_firstLoad_nilCache_refetches() {
        XCTAssertTrue(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: nil, currentCwd: "/A"))
    }
    func test_nilCwd_noRequest() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .full, cachedCwd: nil, currentCwd: nil))
    }
    func test_turnMode_noFullFetch() {
        XCTAssertFalse(ReviewTabView.shouldRefetchFullDiff(mode: .turn, cachedCwd: nil, currentCwd: "/A"))
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/ReviewFullDiffCacheTests`
Expected: 编译失败（`shouldRefetchFullDiff` 未定义）。

- [x] **Step 3: 实现纯函数 + 接线 .task 复合键**

在 `ReviewTabView` 加静态纯函数（放在 `body` 之后、`}` 之前）：

```swift
    /// #2：全量 diff 是否需重取——`.full` 且 cwd 非空且与已缓存 cwd 不同才重取。
    /// cwd 为空不请求；`.turn` 不走全量。纯函数便于单测。
    static func shouldRefetchFullDiff(mode: ReviewSourceMode, cachedCwd: String?, currentCwd: String?) -> Bool {
        guard mode == .full, let currentCwd else { return false }
        return cachedCwd != currentCwd
    }
```

新增记录缓存归属 cwd 的 state（在 `@State private var fullDiff: String?` 下一行）：

```swift
    /// #2：fullDiff 当前所属 cwd；切 thread（cwd 变）后与选中 cwd 不符即失效重取。
    @State private var fullDiffCwd: String?
```

把 `.task(id: mode)`（第 59–65 行）整体替换为按 `mode+cwd` 复合键触发、并用纯函数守卫：

```swift
        // #2：绑定 mode + cwd 复合键；cwd 变即重跑 task。取指纹 String(describing:) 避免依赖 rawValue。
        .task(id: "\(String(describing: mode))|\(cwd ?? "")") {
            guard mode == .full, let cwd, let fetch = activeConversation.fetchFullDiff else { return }
            // 同 cwd 已缓存则不重复拉取；换 cwd 则失效重取（纯函数单一真源）。
            guard Self.shouldRefetchFullDiff(mode: mode, cachedCwd: fullDiffCwd, currentCwd: cwd) else { return }
            loadingFull = true
            fullDiff = await fetch(cwd)
            fullDiffCwd = cwd
            loadingFull = false
        }
```

- [x] **Step 4: 跑测试确认通过**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/ReviewFullDiffCacheTests`
Expected: PASS（5 个用例全绿）。

- [x] **Step 5: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 6: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/ReviewTabView.swift ios/CodexRemoteTests/ReviewFullDiffCacheTests.swift
git commit -m "fix(#2): invalidate full-diff cache by mode+cwd composite key"
```

---

## Task 2（#3 · tasks 1.2）：分屏中间档右栏据实展开（lastRequested tiebreaker）

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift`（新增 `RequestedSide` 枚举 + `columnVisibilityPlan` 加参数）
- Modify: `ios/CodexRemote/Stores/WorkspaceLayoutStore.swift`（记录 `lastRequested`）
- Modify: `ios/CodexRemote/Views/Workspace/ResizableColumns.swift`（透传 `lastRequested`）
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（左栏 toggle / 右栏 toggle 更新 `lastRequested`；透传给 ResizableColumns）
- Test: `ios/CodexRemoteTests/WorkspaceMetricsTests.swift`（追加档位穷举）

**Interfaces:**
- Produces: `enum WorkspaceMetrics.RequestedSide { case left, right, none }`；`columnVisibilityPlan(total:wantLeft:wantRight:lastRequested:) -> ColumnVisibilityPlan`（`lastRequested` 默认 `.none`，保持既有调用点与既有测试编译不破）。
- Consumes: `WorkspaceLayoutStore.leftVisible` / `showRight`。

- [x] **Step 1: 写失败测试**

在 `ios/CodexRemoteTests/WorkspaceMetricsTests.swift` 末尾（`testPlanRespectsUserIntent` 之后、类结束 `}` 之前）追加：

```swift

    // MARK: - #3 中间档 [494,668) lastRequested tiebreaker

    /// [494,668) 且左右都想要、最后点右 → 展开右栏（收左栏），右栏入口不再静默失效。
    func testMidBandBothWantedLastRightExpandsRight() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertFalse(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// [494,668) 且左右都想要、最后点左 → 展开左栏（收右栏）。
    func testMidBandBothWantedLastLeftExpandsLeft() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: true, wantRight: true, lastRequested: .left)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }

    /// [494,668) 只想要右栏（不要左）→ 展开右栏。
    func testMidBandOnlyRightExpandsRight() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: false, wantRight: true, lastRequested: .none)
        XCTAssertFalse(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// [454,494) 仅左+中可容纳：即便最后点右，右栏物理放不下 → 展开左栏。
    func testNarrowBandRightNotFittableFallsBackLeft() {
        // 454 <= 470 < 494（centerPlusRight=280+200+14=494）。
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 470, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }

    /// 全屏 834（竖）/ 1194（横）三栏齐全，不触发降级。
    func testFullscreenWidthsKeepAllThree() {
        for w in [CGFloat(834), CGFloat(1194)] {
            let plan = WorkspaceMetrics.columnVisibilityPlan(
                total: w, wantLeft: true, wantRight: true, lastRequested: .left)
            XCTAssertTrue(plan.showLeft, "w=\(w)"); XCTAssertTrue(plan.showRight, "w=\(w)")
        }
    }

    /// 极窄 320：仅中栏（右栏 <494 属既有 gap，已登记 BACKLOG，不在本轮修）。
    func testUltraNarrowKeepsCenterOnly() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 320, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertFalse(plan.showLeft); XCTAssertFalse(plan.showRight)
    }
```

> 注：既有 `testNarrowPlanCollapsesRightFirst`（total=500，无 `lastRequested` 参数）依赖新参数默认 `.none` → 走「展开左栏」分支，结果 showLeft=true/showRight=false 不变，不回归。

- [x] **Step 2: 跑测试确认失败**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/WorkspaceMetricsTests`
Expected: 编译失败（`RequestedSide` 与新参数未定义）。

- [x] **Step 3: 实现 RequestedSide + 改档位逻辑（保纯函数）**

在 `WorkspaceMetrics.swift` 的 `ColumnVisibilityPlan` 定义（第 55 行）之后插入枚举：

```swift
    /// #3：窄窗中间档 tiebreaker——记录最近一次被用户请求打开的侧栏。
    enum RequestedSide { case left, right, none }
```

把 `columnVisibilityPlan(total:wantLeft:wantRight:)`（第 60–77 行）整体替换为：

```swift
    static func columnVisibilityPlan(total: CGFloat, wantLeft: Bool, wantRight: Bool,
                                     lastRequested: RequestedSide = .none) -> ColumnVisibilityPlan {
        // 充足（≥668）：尊重用户意图，原样。
        if total >= threeColumnMinTotalWidth {
            return ColumnVisibilityPlan(showLeft: wantLeft, showRight: wantRight)
        }
        let leftPlusCenter = leftColumnMinWidth + centerColumnMinWidth + resizableDividerHitWidth   // 454
        let centerPlusRight = centerColumnMinWidth + rightColumnMinWidth + resizableDividerHitWidth  // 494
        // 中间档 [494,668)：左右单侧都物理可容纳但不能同时。
        if total >= centerPlusRight {
            let wantBoth = wantLeft && wantRight
            if wantBoth {
                // 按最后请求侧展开单侧（.right → 右，其余 → 左）——消除「一票保左丢右」死按钮。
                return lastRequested == .right
                    ? ColumnVisibilityPlan(showLeft: false, showRight: true)
                    : ColumnVisibilityPlan(showLeft: true, showRight: false)
            }
            if wantRight { return ColumnVisibilityPlan(showLeft: false, showRight: true) }
            if wantLeft { return ColumnVisibilityPlan(showLeft: true, showRight: false) }
            return ColumnVisibilityPlan(showLeft: false, showRight: false)
        }
        // 窄档 [454,494)：只容纳左+中 → 有 wantLeft 则保左（右栏物理放不下）。
        if wantLeft, total >= leftPlusCenter {
            return ColumnVisibilityPlan(showLeft: true, showRight: false)
        }
        // 极窄 (<454)：仅中栏。
        return ColumnVisibilityPlan(showLeft: false, showRight: false)
    }
```

- [x] **Step 4: 跑测试确认通过**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/WorkspaceMetricsTests`
Expected: PASS（新增 6 + 既有档位用例全绿，无回归）。

- [x] **Step 5: WorkspaceLayoutStore 记录 lastRequested**

在 `WorkspaceLayoutStore.swift` 的 `pendingRightPanelIntent` 字段（第 34 行）后加：

```swift
    /// #3：最近一次被打开的侧栏——供 ResizableColumns 在窄窗中间档做 tiebreaker。
    var lastRequested: WorkspaceMetrics.RequestedSide = .none
```

在 `requestRightPanel(_:)`（第 53 行）内 `showRight = true` 之后加一行：

```swift
        lastRequested = .right
```

- [x] **Step 6: ResizableColumns 透传 lastRequested**

在 `ResizableColumns.swift` 的 `let rightVisible: Bool`（第 17 行）后加一个属性：

```swift
    /// #3：窄窗中间档 tiebreaker（哪侧是用户最后请求）。
    let lastRequested: WorkspaceMetrics.RequestedSide
```

把 `columnVisibilityPlan(...)` 调用（第 38–39 行）加实参：

```swift
            let plan = WorkspaceMetrics.columnVisibilityPlan(
                total: total, wantLeft: leftVisible, wantRight: rightVisible,
                lastRequested: lastRequested)
```

- [x] **Step 7: RootSplitView 更新 lastRequested + 传参**

在 `RootSplitView.swift` 左面板 toggle 按钮（第 147–149 行）改为同时记左侧：

```swift
            Button {
                withAnimation { layout.leftVisible.toggle(); layout.lastRequested = .left }
            } label: { Image(systemName: "rectangle.leadinghalf.inset.filled") }
            .accessibilityLabel(Text("workspace.leftPanel.toggle"))
```

右面板 toggle 按钮（第 165–167 行）改为同时记右侧：

```swift
            Button {
                withAnimation { layout.showRight.toggle(); layout.lastRequested = .right }
            } label: { Image(systemName: "rectangle.trailinghalf.inset.filled") }
            .accessibilityLabel(Text("workspace.rightPanel.toggle"))
```

在 `resizableColumns` 计算属性（第 188–194 行）的 `ResizableColumns(...)` 实参里，`rightVisible: layout.showRight,` 之后加：

```swift
            lastRequested: layout.lastRequested,
```

- [x] **Step 8: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 9: 真机/模拟器分屏验收（ui-adaptation-baseline）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

在 iPad 上把 app 拖到分屏中间档（宽度落 [494,668)）：先点左面板再点右面板 → 右栏展开（左收）；再点左面板 → 左栏展开（右收）。全屏（竖 834 / 横 1194）三栏齐全。横竖屏各验一遍。

- [x] **Step 10: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift ios/CodexRemote/Stores/WorkspaceLayoutStore.swift ios/CodexRemote/Views/Workspace/ResizableColumns.swift ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemoteTests/WorkspaceMetricsTests.swift
git commit -m "fix(#3): expand requested side in mid-band split via lastRequested tiebreaker"
```

---

## Task 3（#5-A · tasks 1.3 上半）：消除占位假串 + 补 Store 文案 xcstrings 键

**Files:**
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`
- Test: `ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift`（把新键加入既有 keys 列表；补假串守卫）

**Interfaces:**
- Produces: 正确的 `conv.item.unknown`（en/zh），以及 Store 展示文案键 `conn.error.*` / `fileBrowser.loadDirFailed`（Task 4 消费）。

- [x] **Step 1: 修 `conv.item.unknown` 占位假串**

在 `Localizable.xcstrings` 定位 `"conv.item.unknown"`（约第 1172 行）。把 en 的 `"value": "帮紧你，帮紧你"` 改为 `"Unknown item"`；把 zh-Hans 的 `"value": "帮紧你，帮紧你"` 改为 `"未知条目"`。

- [x] **Step 2: 新增 Store 展示文案键**

在 `Localizable.xcstrings` 的 `"strings": {` 对象内（任意键之间，保持 JSON 合法、逗号正确）新增以下键（每个含 en / zh-Hans 两语言，格式对齐既有条目 `stringUnit.state="translated"`）。带 `%@` 的为 `String(format:)` 用格式串：

| key | en | zh-Hans |
|---|---|---|
| `conn.error.pairingMissing` | `Relay pairing info missing` | `relay 配对信息缺失` |
| `conn.error.trustRevoked` | `Trust removed by host machine; please re-pair` | `已被开发机移除信任，请重新配对` |
| `conn.error.timeout` | `Connection timed out` | `连接超时` |
| `conn.error.timeoutDetail` | `Connection timed out (connect/handshake did not finish within 20s)` | `连接超时（连接或握手在 20 秒内未完成）` |
| `conn.error.connectionFailed` | `Connection failed, please retry later` | `连接失败，请稍后重试` |
| `conn.error.proxyFailed` | `Channel setup failed: %@` | `通道建立失败：%@` |
| `conn.error.channelClosed` | `Connection channel closed: %@` | `连接通道关闭：%@` |
| `conn.error.channelClosedUnknown` | `Unknown reason` | `未知原因` |
| `conn.error.notConnected` | `Not connected` | `未连接` |
| `conn.error.handshakeFailed` | `WebSocket handshake failed: %@` | `WebSocket 握手失败：%@` |
| `fileBrowser.loadDirFailed` | `Failed to load directory` | `目录加载失败` |

单条模板（复制粘贴改 key/value）：

```json
    "conn.error.pairingMissing": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Relay pairing info missing" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "relay 配对信息缺失" } }
      }
    },
```

- [x] **Step 3: 扩充守卫测试（含无假串 + 新键可解析）**

在 `LocalizationFollowsInjectedLocaleTests.swift` 的 `keys` 数组末尾补入新键：

```swift
        "conv.item.unknown",
        "conn.error.pairingMissing", "conn.error.trustRevoked",
        "conn.error.timeout", "conn.error.timeoutDetail", "conn.error.connectionFailed",
        "conn.error.proxyFailed", "conn.error.channelClosed", "conn.error.channelClosedUnknown",
        "conn.error.notConnected", "conn.error.handshakeFailed",
        "fileBrowser.loadDirFailed",
```

并新增一个「无占位假串」守卫测试方法（加到类内）：

```swift
    /// #5：占位假串（如「帮紧你」）不得残留在任何面向用户键。
    func test_noPlaceholderJokeStrings() {
        let langs = [Locale(identifier: "en"), Locale(identifier: "zh-Hans")]
        let banned = ["帮紧你"]
        let sampleKeys = ["conv.item.unknown"]   // 已知曾中招的键，作显式回归锚
        for key in sampleKeys {
            for locale in langs {
                let s = L10n.string(key, locale: locale)
                for b in banned {
                    XCTAssertFalse(s.contains(b), "占位假串残留 \(key)@\(locale.identifier)=\(s)")
                }
            }
        }
    }
```

- [x] **Step 4: 跑测试确认通过**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`
Expected: PASS（新键 en 无 CJK 残留检查会校验 `conn.error.*` 英文文案；假串守卫绿）。
> 若 en 校验对 `conn.error.timeoutDetail` 等报「含中文残留」，说明该键 en 文案漏填——补齐英文即可。

- [x] **Step 5: Commit**

```bash
git add ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift
git commit -m "fix(#5): remove placeholder joke string; add Store user-facing localization keys"
```

---

## Task 4（#5-B · tasks 1.3 下半）：Store 文案跟随注入 locale（L10n + LocaleManager.currentLocale）

**Files:**
- Modify: `ios/CodexRemote/App/AppearanceManagers.swift`（加静态 `LocaleManager.currentLocale`）
- Modify: `ios/CodexRemote/Stores/ConnectionStore.swift`（用户可见串走 `L10n.string`）
- Modify: `ios/CodexRemote/Stores/FileBrowserStore.swift`（`目录加载失败` → `L10n.string`）
- Test: `ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift`（补 Store 文案注入 locale 单测）

**Interfaces:**
- Consumes: `L10n.string(_:locale:)`（`LocalizedBundle.swift:6`）、Task 3 新增的 `conn.error.*` / `fileBrowser.loadDirFailed` 键。
- Produces: `static var LocaleManager.currentLocale: Locale`（读同一 `app_language` UserDefaults，与 `.environment(\.locale)` 注入同源）。

> 安全边界（Global Constraints）：只改**用户可见展示串**（`.failed(...)` 文案、`node.error`）；`.failed(String)` 契约不变（仍是 String）；`connLog.*` 日志中文串**不碰**；不触任何 relay/transport/Keychain 逻辑。

- [x] **Step 1: 写失败测试**

在 `LocalizationFollowsInjectedLocaleTests.swift` 加：

```swift
    /// #5：ConnectionStore.friendlyMessage 跟随注入 locale；en 无中文残留、zh 为中文。
    func test_connectionFriendlyMessage_followsInjectedLocale() {
        // 注入 en：写持久化键，currentLocale 应解析为 en。
        UserDefaults.standard.set(AppLanguage.en.rawValue, forKey: "app_language")
        let en = ConnectionStore.friendlyMessage(TransportError.notConnected)
        XCTAssertFalse(en.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "en 文案含中文残留：\(en)")

        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: "app_language")
        let zh = ConnectionStore.friendlyMessage(TransportError.notConnected)
        XCTAssertTrue(zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "zh 文案应为中文：\(zh)")

        UserDefaults.standard.removeObject(forKey: "app_language")
    }

    /// #5：currentLocale 读持久化 app_language，与注入同源。
    func test_currentLocale_readsPersistedLanguage() {
        UserDefaults.standard.set(AppLanguage.en.rawValue, forKey: "app_language")
        XCTAssertEqual(LocaleManager.currentLocale.identifier, "en")
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: "app_language")
        XCTAssertEqual(LocaleManager.currentLocale.identifier, "zh-Hans")
        UserDefaults.standard.removeObject(forKey: "app_language")
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`
Expected: 编译失败（`LocaleManager.currentLocale` 未定义）+ 断言失败（friendlyMessage 仍硬编码中文）。

- [x] **Step 3: 加 `LocaleManager.currentLocale`**

在 `AppearanceManagers.swift` 的 `LocaleManager` 类内 `var locale: Locale { ... }`（第 54 行）之后加：

```swift

    /// D5：无 SwiftUI 环境可读的层（Store）从持久化 app_language 解析当前 locale，
    /// 与根视图 `.environment(\.locale, locale)` 注入同源。不用 `String(localized:)`（按系统语言选表）。
    static var currentLocale: Locale {
        let raw = UserDefaults.standard.string(forKey: key)
        let lang = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        return Locale(identifier: lang.localeIdentifier())
    }
```

> `key` 是 `LocaleManager` 的 `private static let key = "app_language"`（第 39 行），同类内可直接引用。

- [x] **Step 4: ConnectionStore 用户可见串走 L10n**

在 `ConnectionStore.swift` 定位并替换（只改展示串，日志不动）：

`ConnectionTimeoutError`（第 8–10 行）：

```swift
struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? { L10n.string("conn.error.timeoutDetail", locale: LocaleManager.currentLocale) }
}
```

`connect(config:)` 内配对缺失（`phase = .failed("relay 配对信息缺失")`）：

```swift
            phase = .failed(L10n.string("conn.error.pairingMissing", locale: LocaleManager.currentLocale))
```

catch 内 trustRevoked（`self.phase = .failed("已被开发机移除信任，请重新配对")`，约第 224 行）：

```swift
                    self.phase = .failed(L10n.string("conn.error.trustRevoked", locale: LocaleManager.currentLocale))
```

超时兜底（`self.phase = .failed(ConnectionTimeoutError().errorDescription ?? "连接超时")`，约第 238 行）：

```swift
            self.phase = .failed(ConnectionTimeoutError().errorDescription
                ?? L10n.string("conn.error.timeout", locale: LocaleManager.currentLocale))
```

live 重连 `.connectionFailed`（`self.phase = .failed("连接失败，请稍后重试")`，约第 432 行）：

```swift
                    self.phase = .failed(L10n.string("conn.error.connectionFailed", locale: LocaleManager.currentLocale))
```

live 重连 `.trustRevoked`（`self.phase = .failed("已被开发机移除信任，请重新配对")`，约第 438 行）：

```swift
                    self.phase = .failed(L10n.string("conn.error.trustRevoked", locale: LocaleManager.currentLocale))
```

`friendlyMessage(_:)`（约第 454–461 行）switch 全部展示串：

```swift
    static func friendlyMessage(_ error: Error) -> String {
        let loc = LocaleManager.currentLocale
        if let t = error as? TransportError {
            switch t {
            case .proxyFailed(let m):
                return String(format: L10n.string("conn.error.proxyFailed", locale: loc), m)
            case .channelClosed(let r):
                return String(format: L10n.string("conn.error.channelClosed", locale: loc),
                              r ?? L10n.string("conn.error.channelClosedUnknown", locale: loc))
            case .notConnected:
                return L10n.string("conn.error.notConnected", locale: loc)
            case .handshakeFailed(let m):
                return String(format: L10n.string("conn.error.handshakeFailed", locale: loc), m)
            case .trustRevoked:
                return L10n.string("conn.error.trustRevoked", locale: loc)
            }
        }
        if let to = error as? ConnectionTimeoutError {
            return to.errorDescription ?? L10n.string("conn.error.timeout", locale: loc)
        }
        return error.localizedDescription
    }
```

> 不改 `connLog.error(...)` / `connLog.info(...)` 里的中文日志串——它们非用户可见，属开发者日志（spec 明确不在约束内）。

- [x] **Step 5: FileBrowserStore 目录加载失败串走 L10n**

在 `FileBrowserStore.swift` 第 103 行 `node.error = "目录加载失败"` 改为：

```swift
            node.error = L10n.string("fileBrowser.loadDirFailed", locale: LocaleManager.currentLocale)
```

- [x] **Step 6: 跑测试确认通过**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`
Expected: PASS。

- [x] **Step 7: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 8: 安全面零触碰自查**

Run: `git diff --stat` 确认只动 `AppearanceManagers.swift` / `ConnectionStore.swift` / `FileBrowserStore.swift` 的展示串行；`git diff ios/CodexRemote/Stores/ConnectionStore.swift | grep -E "^\+" | grep -i "connLog"` 应为空（未改日志）。

- [x] **Step 9: Commit**

```bash
git add ios/CodexRemote/App/AppearanceManagers.swift ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemote/Stores/FileBrowserStore.swift ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift
git commit -m "fix(#5): Store user-facing strings follow injected locale via L10n+currentLocale"
```

---

## Task 5（#4 · tasks 2.1）：接线摘要浮层 → 右栏审查面板跳转

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（注入 `onOpenReview`）
- Modify: `ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift`（删「后续接」注释）

**Interfaces:**
- Consumes: `WorkspaceLayoutStore.requestRightPanel(.review)`（`WorkspaceLayoutStore.swift:53`，置 `showRight=true` + `pendingRightPanelIntent=.review` + Task 2 已加 `lastRequested=.right`）、`SummaryPopoverView.onOpenReview: (() -> Void)?`。

> 安全边界：只用只读跳转意图，**不写** `ActiveConversationHolder` 等会话共享状态（规避首轮 D1 侧聊/主对话串台）。

- [x] **Step 1: RootSplitView 注入 onOpenReview**

在 `RootSplitView.swift` 的 `SummaryPopoverView(...)` 构造（第 75 行）加 `onOpenReview` 实参：

```swift
                        SummaryPopoverView(state: activeConversation.state, thread: selectedThread, env: envInspector,
                                           onOpenReview: { layout.requestRightPanel(.review) })
```

- [x] **Step 2: 删「后续接」注释**

在 `SummaryPopoverView.swift` 第 9 行把注释

```swift
    var onOpenReview: (() -> Void)? = nil              // 批次⑤：变更→审查面板跳转信号（后续接）
```

改为

```swift
    var onOpenReview: (() -> Void)? = nil              // #4：变更→右栏审查面板跳转（RootSplitView 注入 requestRightPanel(.review)）
```

- [x] **Step 3: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 4: 模拟器/真机验收（ui-adaptation-baseline）**

全屏（>668）打开摘要浮层（顶栏 :≡）→ 在「变更」行看到 chevron 不再灰（可点）→ 点击 → 右栏打开并选中「审查」tab，展示当前工作区变更。横竖屏各验；分屏中间档下点击=最后请求右侧（与 Task 2 tiebreaker 协同，右栏展开）。确认主对话内容未串台。

- [x] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift
git commit -m "feat(#4): wire summary popover changes row to open right review panel"
```

---

## Task 6（#6 · tasks 2.2）：a11y 空标签开关补语义标签 + 点按控件 button trait

**Files:**
- Modify: `ios/CodexRemote/Views/Settings/SkillsGroupContent.swift`

**Interfaces:** 无下游依赖。

- [x] **Step 1: SkillsGroupContent 空 Toggle 补 accessibilityLabel**

在 `SkillsGroupContent.swift` 的 `Toggle("", isOn: ...)`（第 30–36 行）末尾（`.labelsHidden()` 之后）加：

```swift
                .labelsHidden()
                .accessibilityLabel(Text(skill.name))
```

- [x] **Step 2: 复查本文件其它空标签/手势点按控件**

Run: `grep -n 'Toggle("")\|onTapGesture' ios/CodexRemote/Views/Settings/SkillsGroupContent.swift`
- 若还有其它空标签 `Toggle("")`，同样补 `.accessibilityLabel(Text(<对应名>))`。
- 若有 `onTapGesture` 实现的点按控件，补 `.accessibilityAddTraits(.isButton)`（沿用首轮 D7 触控范式）。
- 本文件当前只有 skillRow 的一个 Toggle 与 Button/菜单（Button 天然有 button trait），预期无额外改动。

- [x] **Step 3: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 4: VoiceOver 验收**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

模拟器开 Accessibility Inspector（或真机 VoiceOver）聚焦某个 skill 开关 → 朗读出对应 skill 名（不再是空/「开关」）。

- [x] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/Settings/SkillsGroupContent.swift
git commit -m "fix(#6): add accessibilityLabel to empty skill toggles for VoiceOver"
```

---

## Task 7（#7 · tasks 2.3）：活动机器 tab 自动滚入可见区

**Files:**
- Modify: `ios/CodexRemote/Views/TabBarView.swift`

**Interfaces:**
- Consumes: `SessionsManager.activeSessionId`、`MachineConfig.id`。

> energy-awareness：仅由 `activeSessionId` 变化事件驱动，无定时器/轮询。

- [x] **Step 1: 外套 ScrollViewReader + tab .id + onChange scrollTo**

在 `TabBarView.swift` 的 `body`（第 15 行起）：把 `ScrollView(.horizontal, ...) { ... }` 整体用 `ScrollViewReader { proxy in ... }` 包裹，给每个 tab 加 `.id(m.id)`，并在 `ScrollView` 上加 `onChange`。具体：

`body` 改为：

```swift
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sessions.machineStore.machines) { m in
                        tab(m).id(m.id)
                    }
                    addButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            // #7：活动 session 变化 → 把活动 tab 居中滚入（事件驱动，无定时器）。
            .onChange(of: sessions.activeSessionId) { _, newId in
                guard let newId else { return }
                withAnimation { proxy.scrollTo(newId, anchor: .center) }
            }
            .background(.bar)
            .alert("tab.capReached", isPresented: $showCapAlert) {
                Button("common.ok", role: .cancel) {}
            }
            .alert("tab.rename.title", isPresented: renameAlertBinding) {
                TextField("tab.rename.placeholder", text: $renameDraft)
                Button("common.cancel", role: .cancel) { renameTarget = nil }
                Button("tab.rename.confirm") {
                    if let id = renameTarget { sessions.rename(id: id, to: renameDraft) }
                    renameTarget = nil
                }
            }
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
        }
    }
```

> 注：把既有 `.background/.alert/.confirmationDialog` 修饰符从 `ScrollView` 平移到 `ScrollView`（仍挂在同一 `ScrollView` 上，只是外层多了 `ScrollViewReader`）。逻辑不变，仅新增 `ScrollViewReader` + `.id` + `.onChange`。

- [x] **Step 2: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 3: 模拟器/真机验收（ui-adaptation-baseline）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

添加足够多机器让 tab 栏溢出可横滑。用 ⌘数字 / 相邻 tab 快捷键切到一个当前离屏的 tab → 该 tab 自动滚到居中可见。横竖屏各验一遍。

- [x] **Step 4: 能耗自查（energy-awareness）**

确认无新增 `Timer` / `Task.sleep` 循环 / 轮询；滚动仅由 `onChange(of: activeSessionId)` 触发。

- [x] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/TabBarView.swift
git commit -m "feat(#7): auto-scroll active machine tab into view (event-driven)"
```

---

## Task 8（#8-A · tasks 3.1）：审查面板 diff 查看器可读性四项

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/ReviewPanelView.swift`

**Interfaces:**
- Consumes: `DiffFile.hunks` / `DiffLine`（`ReviewPanelView.swift` 现有类型）。selectable 先例：`ItemCards.swift:265`（`DiffView` 逐行 `.textSelection(.enabled)`）。

> 四项：(a) 行号 gutter；(b) 长行横滚不折行（横滚只包正文区，外层纵向 + 520 横竖自适应布局不变，守 R2）；(c) `.textSelection(.enabled)`；(d) 字号 `caption2 → caption` + 行高。

- [x] **Step 1: 重写 diffArea（横滚只包正文）**

把 `ReviewPanelView.swift` 的 `diffArea`（第 33–46 行）替换为：

```swift
    private var diffArea: some View {
        ScrollView {                                   // 外层纵向（不变）
            if let f = selected {
                ScrollView(.horizontal, showsIndicators: true) {   // #8b：横滚只包正文区
                    VStack(alignment: .leading, spacing: 0) {
                        // 逐 hunk 展平行，计算 1-based 行号（无文件行号则用序号）。
                        let rows = Array(f.hunks.flatMap { $0.lines }.enumerated())
                        ForEach(rows, id: \.offset) { idx, line in
                            diffLineRow(line, lineNumber: idx + 1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)  // #8b：不折行，随内容变宽
                }
            }
        }
    }
```

- [x] **Step 2: 重写 diffLineRow（gutter + 可选 + 字号）**

把 `diffLineRow(_:)`（第 48–61 行）替换为：

```swift
    private func diffLineRow(_ line: DiffLine, lineNumber: Int) -> some View {
        let (bg, prefix): (Color, String) = {
            switch line.kind {
            case .add: return (.green.opacity(0.18), "+")
            case .del: return (.red.opacity(0.18), "-")
            case .context: return (.clear, " ")
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            // #8a：定宽 monospace 行号 gutter。
            Text("\(lineNumber)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(prefix + line.text)
                .font(.system(.caption, design: .monospaced))   // #8d：caption2 → caption
                .textSelection(.enabled)                          // #8c：可选可复制
                .lineSpacing(2)                                   // #8d：行高
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(bg)
    }
```

- [x] **Step 3: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 4: 真机/模拟器验收（ui-adaptation-baseline + R2）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

打开右栏审查 tab，选中一个含长行的文件 diff：每行左侧显示行号；长行不软换行、可在正文区内横向滚动；可长按选中复制；字号较前略大易读。**重点验 R2**：正文横滚与外层纵向不打架、宽度 ≥520 时左右布局 / <520 时上下布局仍正确，横竖屏各验一遍。

- [x] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/ReviewPanelView.swift
git commit -m "feat(#8): diff viewer readability — line gutter, h-scroll, selection, larger font"
```

---

## Task 9（#8-B · tasks 3.2）：文件查看器可读性四项

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/FileBrowserView.swift`

**Interfaces:**
- Consumes: `store.selectedFile?.content` 的 `.text(String)` 分支（`FileBrowserView.swift:120-124`）。

> 与 Task 8 同四项，作用于 `contentArea` 的 `.text` 正文。文件查看器用 1-based 行号。

- [x] **Step 1: 重写 contentArea 的 .text 分支为分行 + gutter + 横滚**

把 `FileBrowserView.swift` 的 `contentArea`（第 112–135 行）中 `.text(let s)` 分支替换为调用新私有子视图；把整个 `contentArea` 替换为：

```swift
    @ViewBuilder private var contentArea: some View {
        ScrollView {                                   // 外层纵向（不变）
            if store.isOpeningFile {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
            } else {
                switch store.selectedFile?.content {
                case .text(let s):
                    fileTextBody(s)
                case .tooLarge:
                    placeholder("fileBrowser.tooLarge")
                case .binary:
                    placeholder("fileBrowser.binary")
                case nil:
                    placeholder("fileBrowser.selectFile")
                }
            }
        }
    }

    /// #8：文件正文——1-based 行号 gutter + 长行横滚不折行 + 可选 + 略大字号/行高。
    private func fileTextBody(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {       // #8b：横滚只包正文区
            VStack(alignment: .leading, spacing: 0) {
                let lines = Array(s.split(separator: "\n", omittingEmptySubsequences: false).enumerated())
                ForEach(lines, id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1)")                     // #8a：1-based 行号 gutter
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(.caption, design: .monospaced))   // #8d：caption2 → caption
                            .textSelection(.enabled)                        // #8c：可选可复制
                            .lineSpacing(2)                                  // #8d：行高
                    }
                }
            }
            .padding(8)
            .fixedSize(horizontal: true, vertical: false)      // #8b：不折行
        }
    }
```

- [x] **Step 2: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 3: 真机/模拟器验收（ui-adaptation-baseline + R2）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

文件浏览 tab 打开一个含长行的文本文件：每行显示 1-based 行号；长行横滚不折行；可选中复制；字号略大。验 ≥520 左右 / <520 上下自适应布局不破，横竖屏各验。

- [x] **Step 4: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/FileBrowserView.swift
git commit -m "feat(#8): file viewer readability — line gutter, h-scroll, selection, larger font"
```

---

## Task 10（#9 · tasks 3.3）：审查发起可见反馈（Capsule inline 提示）

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/ReviewTabView.swift`

**Interfaces:**
- Consumes: `ActiveConversationHolder.startReview: ((_ mode: ReviewSourceMode) async -> Bool)?`（返回 Bool 现被丢弃）。

> 决策 #9：复用连接横幅 **Capsule 样式** inline 提示条（全 app 现零 toast），`~1.5s` 后由**一次性** `Task.sleep` 收起（先例 `ConversationView.swift:156`）。不加假防抖 `isStarting`，不改 D4 fire-and-forget 本质。energy：一次性 sleep ≈ 0 持续成本，非轮询/定时器。

- [x] **Step 1: 加 reviewFeedback state**

在 `ReviewTabView.swift` 的 `@State private var loadingFull = false`（第 14 行）后加：

```swift
    /// #9：发起审查后的一次性可见反馈（true = 短时显示「审查已发起」Capsule）。
    @State private var showReviewStarted = false
```

- [x] **Step 2: 发起按钮消费返回值 + 触发反馈**

把发起 `Button { ... }`（第 41–45 行）改为消费返回 Bool 并置反馈态：

```swift
                Button {
                    Task {
                        let ok = await activeConversation.startReview?(mode) ?? false
                        guard ok else { return }
                        showReviewStarted = true
                        // 一次性延时收起（无周期唤醒，能耗先例 ConversationView.swift:156）。
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showReviewStarted = false
                    }
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
```

- [x] **Step 3: 面板内叠加 Capsule 提示条**

把 `body` 里数据源区（`if loadingFull { ... } else { ReviewPanelView(source: source) }`，第 52–56 行）用 overlay 叠反馈：

```swift
            Group {
                if loadingFull {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReviewPanelView(source: source)
                }
            }
            .overlay(alignment: .top) {
                if showReviewStarted {
                    // 连接横幅同款 Capsule 样式 inline 提示（无 toast）。
                    Label("review.started", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                        .accessibilityLabel(Text("review.started"))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showReviewStarted)
```

- [x] **Step 4: 加本地化键 `review.started`**

在 `ios/CodexRemote/Resources/Localizable.xcstrings` 新增键 `review.started`：en `Review started`，zh-Hans `审查已发起`（格式同 Task 3 模板）。

- [x] **Step 5: 把 review.started 加入 loc 守卫测试**

在 `LocalizationFollowsInjectedLocaleTests.swift` 的 `keys` 数组补 `"review.started",`。

- [x] **Step 6: 跑 loc 测试 + 构建 guard**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/LocalizationFollowsInjectedLocaleTests`
Expected: PASS。
Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 7: 模拟器/真机验收（ui-adaptation-baseline + energy）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

在有可发起数据源时点发起按钮 → 审查面板顶部短时出现「审查已发起」Capsule，约 1.5s 后淡出。横竖屏各验；确认无定时器（仅一次性 sleep）。

- [x] **Step 8: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/ReviewTabView.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/LocalizationFollowsInjectedLocaleTests.swift
git commit -m "feat(#9): visible inline Capsule feedback after starting review (one-shot dismiss)"
```

---

## Task 11（#10 · tasks 3.4）：近底判定接入生产（GeometryReader + PreferenceKey → 真调策略函数）

**Files:**
- Modify: `ios/CodexRemote/Views/ConversationView.swift`
- Test: `ios/CodexRemoteTests/ConversationScrollAnchorTests.swift`（补 120pt 边界）

**Interfaces:**
- Consumes: `ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:120)`（`ConversationView.swift:5`，现仅测试调用——消灭死代码）。
- Produces: `struct BottomDistanceKey: PreferenceKey`（文件内私有）。

> 决策 B：用 `GeometryReader` 测滚动内容底部到可视底部的 `distanceToBottom`，喂策略函数产出 `isNearBottom`；sentinel 从「判定真源」降为几何测点。iOS 17.0 → 用 `GeometryReader` + `PreferenceKey`（**禁** `onScrollGeometryChange`）。energy：随布局/滚动几何变化事件驱动，无几何轮询/定时器。

- [x] **Step 1: 补 120pt 边界单测（先失败/回归锚）**

把 `ConversationScrollAnchorTests.swift` 的 `test_nearBottomThreshold`（第 15–18 行）替换为：

```swift
    func test_nearBottomThreshold() {
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 40, threshold: 120))
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 119, threshold: 120))
        XCTAssertTrue(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 120, threshold: 120))  // 边界含
        XCTAssertFalse(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 121, threshold: 120))
        XCTAssertFalse(ScrollAnchorPolicy.isNearBottom(distanceToBottom: 400, threshold: 120))
    }
```

- [x] **Step 2: 跑测试确认通过（策略函数已存在）**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/ConversationScrollAnchorTests`
Expected: PASS（`<=` 语义使 120→true）。

- [x] **Step 3: 定义 PreferenceKey**

在 `ConversationView.swift` 顶部 `ScrollAnchorPolicy` 枚举（第 12 行）之后加：

```swift
/// #10：滚动内容底部到可视底部的最小距离（取多个几何读数的 min）。
private struct BottomDistanceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.min(value, nextValue())
    }
}
```

- [x] **Step 4: 外套 GeometryReader 取可视底部 + sentinel 测几何 + onPreferenceChange 喂策略函数**

把 `body`（第 44 行起）的 `ScrollViewReader { proxy in ScrollView { ... } ... }` 结构调整为：外层用 `GeometryReader` 拿视口底部全局 y；底部 sentinel 用背景 `GeometryReader` 上报自身全局 minY 相对视口底部的距离；`onPreferenceChange` 里真调策略函数。

具体：`var body: some View {` 内、`ScrollViewReader { proxy in` 之前包一层 `GeometryReader { outer in`，并在末尾对应补 `}`。把底部 sentinel 行（第 64–66 行）替换为：

```swift
                    // #10：底部几何测点——上报「内容底部 minY − 视口底部 maxY」作 distanceToBottom。
                    // 内容底部在视口内/上方 → 距离 ≤ 0；在视口下方（还没滚到底）→ 正距离。
                    Color.clear.frame(height: 1).id(Self.bottomSentinelID)
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: BottomDistanceKey.self,
                                value: g.frame(in: .global).minY - outer.frame(in: .global).maxY)
                        })
```

把原 `ScrollView { ... }` 上的 `.onChange(of: store?.state.items.count)`（第 70 行）之前，加 `.onPreferenceChange`（挂在 `ScrollView` 上）：

```swift
            .onPreferenceChange(BottomDistanceKey.self) { d in
                // 真调策略函数（threshold=120）——消灭死代码。负距离夹到 0（已贴底）。
                let near = ScrollAnchorPolicy.isNearBottom(distanceToBottom: Swift.max(0, d), threshold: 120)
                isNearBottom = near
                if near { showNewBelow = false }
            }
```

删除 sentinel 的 `.onAppear { isNearBottom = true; showNewBelow = false }` 与 `.onDisappear { isNearBottom = false }`（已被 preference 判定取代，避免与新判定打架成两个真源）。

> 布局注意：外层 `GeometryReader` 会填满并 top-leading 对齐子内容——给内部 `ScrollViewReader`/`ScrollView` 链补 `.frame(maxWidth: .infinity, maxHeight: .infinity)` 以铺满，避免尺寸塌陷。`.safeAreaInset(.bottom)`（composer）、`.overlay`（新消息浮标）等修饰符保持挂在原层级。

- [x] **Step 5: 构建 guard**

Run: `bash ios/comet-build-check.sh`
Expected: BUILD SUCCEEDED。

- [x] **Step 6: 跑对话相关测试无回归**

Run: `xcodebuild test ... -only-testing:CodexRemoteTests/ConversationScrollAnchorTests`
Expected: PASS。

- [x] **Step 7: 真机/模拟器验收（R1 手感 + energy + ui-adaptation-baseline）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

- 贴近底部（距底 ≤120pt）时新消息 → 自动滚到底。
- 向上滚离底部（>120pt）时新消息 → 不自动滚，出现「新消息」浮标，点击回底。
- 对比旧 1px 行为：近底带从 1px 放宽到 120pt，自动滚触发更「跟手」。
- energy：确认仅由滚动/布局几何变化触发 `onPreferenceChange`，无 `Timer`/轮询。
- 横竖屏各验；软键盘弹出（composer 聚焦）时视口底部变化，近底判定仍正确、不误触自动滚。

- [x] **Step 8: Commit**

```bash
git add ios/CodexRemote/Views/ConversationView.swift ios/CodexRemoteTests/ConversationScrollAnchorTests.swift
git commit -m "fix(#10): wire near-bottom decision to isNearBottom(threshold:120) via GeometryReader+PreferenceKey"
```

---

## Task 12（tasks 4.1–4.4）：全量验收与恒定原则守卫

**Files:** 无代码改动（纯验证 + 必要时回补）。

- [x] **Step 1: 全量 iOS 测试绿（4.1）**

Run:
```bash
cd ios && xcodegen generate >/dev/null && cd - >/dev/null
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath ios/DerivedData -quiet
```
Expected: **Test Succeeded**（新增 `ReviewFullDiffCacheTests` + `WorkspaceMetricsTests` 新用例 + `LocalizationFollowsInjectedLocaleTests` 扩充 + `ConversationScrollAnchorTests` 边界，且既有全部回归绿）。

- [x] **Step 2: xcstrings 无占位假串守卫（4.1）**

Run: `grep -n "帮紧你" ios/CodexRemote/Resources/Localizable.xcstrings`
Expected: 无输出（0 匹配）。

- [x] **Step 3: ui-adaptation-baseline 横竖屏总验（4.2）**

  > 验收状态：代码级适配 + 自动化测试已验（531/0，含 520 阈值 / ScrollViewReader / 120pt 边界 / a11y trait / 本地化 / band 穷举）；真机横竖屏 + 手感 + VoiceOver + 软/硬键盘终验由用户在 iPad Pro 11" 完成（需 live Mac daemon 数据，非静默略过，见 tasks.md 4.2）。

对 #3/#4/#7/#8/#9/#10 每项，在 iPad 上横屏 + 竖屏各走一遍关键路径（见各任务验证步）；软键盘/外接键盘弹出时不遮挡、可交互。逐项在本地真机验收清单打勾。

- [x] **Step 4: energy-awareness 自查（4.3）**

Run: `git diff 6a558cf364756a23d29707cf0628179b2f5110d2 -- ios/CodexRemote | grep -nE "Timer|\.repeatForever|Task\.sleep|while true|for await"`
Expected: 仅出现 #9 的**一次性** `Task.sleep(nanoseconds: 1_500_000_000)`（无循环包裹）；无新增 `Timer` / 轮询 / 周期唤醒。#7/#10 应为纯事件驱动（`onChange` / `onPreferenceChange`），不出现在结果里。

- [x] **Step 5: 安全面零触碰核对（4.4）**

Run:
```bash
git diff --name-only 6a558cf364756a23d29707cf0628179b2f5110d2 -- ios/CodexRemote
```
Expected: 改动文件仅限本计划涉及的 UI/展示/store-展示串文件；**不含** relay / transport / Keychain / E2E / security 逻辑文件。

Run:
```bash
git diff 6a558cf364756a23d29707cf0628179b2f5110d2 -- ios/CodexRemote/Stores/ConnectionStore.swift | grep -E "^[+-]" | grep -iE "connLog|Ed25519|X25519|TOFU|handshake\(|transportFactory|Keychain"
```
Expected: 无输出（未改任何 relay/密钥/日志逻辑，仅本地化了展示串）。

- [x] **Step 6: OpenSpec 验证（若走 comet verify 流程）**

按项目 comet-verify 流程校验 8 个 delta spec 的 ADDED 场景均已由上述任务覆盖：
- `ipad-review-panel`（#2 Task 1 + #8-diff Task 8）
- `ipad-right-panel-tabs`（#3 Task 2）
- `ipad-review-actions`（#4 Task 5 + #9 Task 10）
- `ipad-localization`（#5 Task 3/4）
- `ipad-touch-accessibility`（#6 Task 6）
- `ipad-multi-connection`（#7 Task 7）
- `ipad-file-browser`（#8-file Task 9）
- `ipad-conversation-ux`（#10 Task 11）

---

## Self-Review 记录

- **Spec coverage**：8 个 delta spec 需求 ↔ Task 映射见 Task 12 Step 6，逐条有归属。#3 <494pt 超窄档右栏不可达按设计（决策 (a)）**明确不修**、登记 BACKLOG，非遗漏。
- **Placeholder scan**：各步均含具体代码/命令；无 TODO/TBD/「类似 TaskN」。
- **Type consistency**：`shouldRefetchFullDiff(mode:cachedCwd:currentCwd:)`、`RequestedSide{left,right,none}`、`columnVisibilityPlan(...lastRequested:)`、`LocaleManager.currentLocale`、`L10n.string(_:locale:)`、`BottomDistanceKey`、`ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:)`、`review.started` 键 —— 定义处与消费处签名/名称一致。
- **恒定原则**：security（Task 4/12 核对零触碰）、energy（#7/#9/#10 事件驱动，#9 一次性 sleep 有先例）、ui-adaptation（每 UI 任务横竖屏验、iOS17 用 GeometryReader+PreferenceKey）均落到具体步。
