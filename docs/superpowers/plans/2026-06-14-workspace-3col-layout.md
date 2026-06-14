---
change: workspace-3col-layout
design-doc: docs/superpowers/specs/2026-06-14-workspace-3col-layout-design.md
base-ref: addd34718a029d9908f4cd55e5cf8dd12a130ed2
---

# 三列系统列布局重构（workspace-3col-layout）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施本计划。步骤用复选框（`- [ ]`）语法跟踪。
>
> **设计依据：** 全程对照 [docs/superpowers/specs/2026-06-14-workspace-3col-layout-design.md](../specs/2026-06-14-workspace-3col-layout-design.md)（已定稿）。任务边界对照 `openspec/changes/workspace-3col-layout/tasks.md` 与 `.../specs/workspace-layout/spec.md`。

**目标（一句话）：** 把右边栏从自绘横向 resize 列改为系统 `.inspector` 检视列消除拖动闪屏，并把下边栏改为挂在三栏 split 外层的全宽 `.safeAreaInset(.bottom)`（压所有），既有能力零回归。

**架构（2-3 句）：** `RootSplitView` 当前结构是 `split.safeAreaInset(.top){顶栏}`，其中 `split` 的 detail 区被 `WorkspaceDetailRegion` 用 `VStack{ HStack{中栏 + 自绘右栏} ; 下栏 }` 包裹。本 change 把右栏改成中栏 `.inspector(isPresented:$showRightPanel){ RightPanelView }.inspectorColumnWidth(...)`（系统托管 resize，不闪），把下栏从 detail 区内移到整个 `split` 外层 `.safeAreaInset(edge:.bottom)`（全宽、压左+中+右）。关键洞察（design D3）：下栏不再用 VStack 包 detail/inspector → 旧版 inspector 拖不动的根因消除 → inspector 拖动恢复。

**技术栈：** SwiftUI（`NavigationSplitView` + `.inspector` + `.safeAreaInset` + `.overlay`）、XCTest、xcodebuild/xcrun simctl（iOS 模拟器）。

---

## 环境与约定（执行前必读）

**工作目录（worktree 根）：** `/Volumes/mount/codex-for-pados/.claude/worktrees/ipad-workspace-shell`
所有 `xcodebuild` / `git` 命令均在此目录的 `ios/` 或仓库根执行（注意：agent 线程每次 bash 调用 cwd 会重置，命令里请用绝对路径或显式 `-project`/`-derivedDataPath`）。

**项目生成（xcodegen）：** iOS app 用 xcodegen 从 `ios/project.yml` 生成工程，按目录收文件——**本 change 只改/删既有 `.swift`，不新建生产文件，无需 `xcodegen generate` 调整 target 成员**。若 `WorkspaceMetrics.swift` 删了函数后报符号找不到，是测试还引用旧符号（见 Task 4），不是 target 成员问题。

**测试/构建命令（统一用这条，下文各任务直接引用）：**
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -project ios/CodexRemote.xcodeproj
```
> 注：工程文件实际为 `ios/CodexRemote.xcodeproj`（xcodegen 生成）。若该路径不存在，先在 `ios/` 下 `xcodegen generate` 再试。若报模拟器不存在，按 `docs/superpowers/plans/README-dev-setup.md` 创建名为 `iPad-Test` 的模拟器后重试。预期末尾 `** TEST SUCCEEDED **`。

**模拟器自检（截图）三步：**
```bash
# 1. 构建出 .app（test 跑过后产物在 DerivedData 里；或单独 build）
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
# 2. 装 + 启
xcrun simctl install iPad-Test "$(find DerivedData -name CodexRemote.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch iPad-Test com.tangyujie.codexremote
# 3. 截图
xcrun simctl io iPad-Test screenshot /tmp/3col-<状态名>.png
```

**能 CLI 验 vs 只能人工验（design §3/§4，全程牢记）：**
- **能自动化**：既有单测（`WorkspaceMetrics` clamp / `WorkspaceSummary` 派生）；编译通过；模拟器逐态**截图**（看得到「显/隐组合、全宽下栏、橙主题、选中态」是否对）。
- **CLI 验不了、只能用户实测**：拖动是否**平滑不闪**、inspector 是否**真能拖**、下栏拖高是否**跟手**。截图是静态的，证明不了「拖动手感/不闪」。每次报告须显式区分这两类。

**TDD 适用性：** 本 change 是纯 SwiftUI 布局骨架重构，**无新增纯逻辑**（右栏宽改由系统 `.inspectorColumnWidth` 托管，删掉自绘 `resizedRightWidth` 计算）。故无新单测可写；既有单测须不破（Task 4 处理删函数引发的测试连带修改）。除 Task 4 外，验证靠「编译通过 + 截图自检 + 用户实测」。

**提交节奏：** 每个 Task 完成即 `git commit`（comet build 规约：不积攒）。同时在 `openspec/changes/workspace-3col-layout/tasks.md` 勾选对应条目。

---

## 文件结构（改动地图）

| 文件 | 责任 | 本 change 动作 |
|------|------|----------------|
| `ios/CodexRemote/Views/RootSplitView.swift` | 五窗口布局骨架（顶栏/split/detail/overlay/面板 toggle） | **主战场**：右栏改 inspector、下栏移外层、删 `WorkspaceDetailRegion` 右栏部分 |
| `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift` | 面板尺寸常量 + clamp 纯函数 | 删 `resizedRightWidth`（自绘逻辑）；保留宽度常量（供 `.inspectorColumnWidth`）与高度常量/clamp（供下栏） |
| `ios/CodexRemote/Views/Workspace/PanelResizeHandle.swift` | 右栏左缘自绘竖向拖把手 | **整文件删除**（仅右栏用，inspector 取代之） |
| `ios/CodexRemote/Views/Workspace/BottomPanelView.swift` | 下栏自绘横把手 + 纵向拖改高 + 空态 | **不改**（下栏仅换挂载位置，组件本身复用） |
| `ios/CodexRemote/Views/Workspace/RightPanelView.swift` | 右栏内容（本期空态） | **不改**（放进 inspector 即可） |
| `ios/CodexRemote/Views/Workspace/PanelEmptyState.swift` | 右/下栏占位空态 | 不改 |
| `ios/CodexRemoteTests/WorkspaceMetricsTests.swift` | `WorkspaceMetrics` 单测 | 删除引用 `resizedRightWidth` 的 4 个测试（Task 4） |

---

## Task 1: spike —— 验证外层全宽下栏下的 inspector 拖动正常+不闪【最高风险前提，阻塞后续】

> 对应 tasks.md 1.1。design §3「最高风险」+ D3。**这是构建第一步，spike 不通过则暂停，与用户议退路（不在此预先锁定）。**
> 本 spike 用最小复现，**临时**改 `RootSplitView`，验证完即回退（spike 不提交进主线，只为拿到「拖动行不行」的结论）。

**Files:**
- Modify（临时）: `ios/CodexRemote/Views/RootSplitView.swift`

- [ ] **Step 1: 临时把 detail 改成「中栏 .inspector 占位 + 外层全宽下栏」最小形态**

把 `RootSplitView.swift` 的 `detail` 计算属性与 `body` 临时改为下面形态（**只为 spike，保留原代码到一旁/git stash 之外，验证后 Step 5 回退**）。中栏放占位、inspector 放占位、下栏用 `Color` 占位挂外层：

```swift
// 临时 spike：body 改为——split 外层挂全宽下栏 safeAreaInset
var body: some View {
    split
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 全宽占位下栏（验证它压所有 + 不破坏 inspector 拖动）
            Color.orange.opacity(0.25).frame(height: 200)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) { topBar; Divider() }
        }
        .environment(activeConversation)
}

// 临时 spike：detail 改为——中栏内容 + 系统 inspector 占位（不被 VStack 包）
private var detail: some View {
    content
        .inspector(isPresented: .constant(true)) {
            Color.blue.opacity(0.2)
                .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                      ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                      max: WorkspaceMetrics.rightPanelMaxWidth)
        }
        .toolbar(removing: .sidebarToggle)
}
```

- [ ] **Step 2: 编译 + 装到模拟器并启动**

Run:
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
xcrun simctl install iPad-Test "$(find DerivedData -name CodexRemote.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch iPad-Test com.tangyujie.codexremote
```
Expected: `** BUILD SUCCEEDED **`；模拟器出现「左 sidebar · 中内容 · 右蓝色 inspector 列」三栏，底部一条橙色全宽条横跨左+中+右。

- [ ] **Step 3: 截图记录三栏全开静态形态**

Run: `xcrun simctl io iPad-Test screenshot /tmp/3col-spike.png`
Expected: 截图里 inspector（蓝）在最右、底部橙条全宽（含压住左 sidebar）。把截图附进报告。

- [ ] **Step 4: 暂停 → 交用户实测拖动（CLI 验不了）**

报告给用户，请其在模拟器/真机**实测**两点并回报：
1. 左 sidebar 保持打开（三栏全开）时，**拖 inspector 左边界能否改宽、是否平滑不闪**（对照左 sidebar 拖动手感）。
2. inspector 拖动是否受底部全宽下栏 / 顶栏 safeAreaInset 干扰。

判定：
- **正常（可拖 + 不闪）** → spike 通过，继续 Step 5 → Task 2。
- **异常（拖不动 / 仍闪）** → **停止本计划**，按 design §3 退路与用户讨论（保留自绘列换消闪手段 / 右栏固定宽 toggle-only），不要擅自往下做。

- [ ] **Step 5: 回退 spike 临时改动（spike 不进主线）**

把 `RootSplitView.swift` 还原到 spike 前（`git checkout -- ios/CodexRemote/Views/RootSplitView.swift` 或手工撤销 Step 1）。spike 结论写进报告即可，不单独 commit 代码。
Run: `git status` Expected: `RootSplitView.swift` 无改动（已还原）。

> ⚠️ spike 通过后才继续。后续 Task 2/3 才是真正落地（用真实 `$showRightPanel` 绑定、真实 `RightPanelView`、真实 `BottomPanelView`）。

---

## Task 2: 右栏改 `.inspector` 系统检视列 + 删自绘右栏

> 对应 tasks.md 2.1 / 2.2 / 2.4 + 2.3 的「删 WorkspaceDetailRegion 右栏部分 / rightWidth」。design D1。
> 注：`PanelResizeHandle.swift` 整文件删除与 `resizedRightWidth` 删除分别在 Task 5 / Task 4，本任务先让右栏改用 inspector、并清掉 `WorkspaceDetailRegion` 里的右栏自绘代码（rightWidth/rightDragBase/PanelResizeHandle 调用）。

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（`detail`、`WorkspaceDetailRegion`）

- [ ] **Step 1: 把 `detail` 改为中栏内容直接挂 inspector（不再走 WorkspaceDetailRegion 的右栏 HStack）**

> 本步暂保留下栏仍在 `WorkspaceDetailRegion` 里（下栏移外层是 Task 3）。先把右栏从「HStack 自绘列」换成「中栏 `.inspector`」。改 `WorkspaceDetailRegion` 的 `body`：去掉 `HStack` 与 `PanelResizeHandle`、`RightPanelView().frame(width:rightWidth)`，改成中栏 `content.inspector(...)`；下栏暂留原位。

把 `WorkspaceDetailRegion` 整体替换为：

```swift
/// detail 区（中栏对话 .inspector 右栏 + 下栏暂留，下栏移外层见 Task 3）。
private struct WorkspaceDetailRegion<Content: View>: View {
    let showRightPanel: Bool
    let showBottomPanel: Bool
    @ViewBuilder var content: Content

    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: .constant(showRightPanel)) {
                    RightPanelView()
                        .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                              ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                              max: WorkspaceMetrics.rightPanelMaxWidth)
                }
            if showBottomPanel {
                Divider()
                BottomPanelView(height: $bottomHeight)
            }
        }
    }
}
```

> 说明：此处 `isPresented` 暂用 `.constant(showRightPanel)`（`WorkspaceDetailRegion` 只收到 `Bool` 值）。Task 2 Step 3 会把真正的 `Binding` 提上去——把 inspector 直接绑 `RootSplitView.$showRightPanel`，让顶栏按钮 toggle 生效。先编译过这一版。

- [ ] **Step 2: 编译验证（结构先通）**

Run:（用上文「测试/构建命令」）
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** BUILD SUCCEEDED **`（`rightWidth`/`rightDragBase`/`PanelResizeHandle` 调用已从本视图移除；`PanelResizeHandle.swift` 文件本身仍在，Task 5 删）。

- [ ] **Step 3: 把 inspector 的 `isPresented` 真正绑到 `RootSplitView.$showRightPanel`（让顶栏右按钮 toggle 生效）**

inspector 的显隐必须由 `$showRightPanel` 这个 `Binding` 驱动，而非 `.constant`。两种落地选其一，**推荐 A**：

**A（推荐，去掉 WorkspaceDetailRegion 的右栏职责，inspector 直接挂在 RootSplitView 的 detail content 上）：**
把 `RootSplitView.detail` 改为直接挂 inspector，下栏暂仍交给一个只管下栏的轻量包装（或暂留 VStack，Task 3 再清）：

```swift
// RootSplitView 内
@State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

private var detail: some View {
    VStack(spacing: 0) {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $showRightPanel) {
                RightPanelView()
                    .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                          ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                          max: WorkspaceMetrics.rightPanelMaxWidth)
            }
        if showBottomPanel {
            Divider()
            BottomPanelView(height: $bottomHeight)
        }
    }
}
```
并**删除 `WorkspaceDetailRegion` 结构体**（其职责已并回 `detail`；下栏移外层在 Task 3 完成后这里的 VStack 也会拆掉）。`bottomHeight` 状态上移到 `RootSplitView`（design D2 注：状态留在 RootSplitView 或其子皆可）。

> 选 A 的理由：inspector 必须能拿到 `RootSplitView` 的 `$showRightPanel` Binding；把 detail 直接写在 RootSplitView 最直接。Task 3 会把这里的 VStack/下栏整段挪到外层，detail 最终只剩 `content.inspector(...)`。

- [ ] **Step 4: 编译验证 toggle 绑定**

Run:
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 模拟器自检右栏显隐（截图，静态可验）**

Run:
```bash
xcrun simctl install iPad-Test "$(find DerivedData -name CodexRemote.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch iPad-Test com.tangyujie.codexremote
xcrun simctl io iPad-Test screenshot /tmp/3col-right-on.png
# 点顶栏右面板按钮（rectangle.trailinghalf.inset.filled）切隐藏后再截
xcrun simctl io iPad-Test screenshot /tmp/3col-right-off.png
```
Expected: on 图右侧出现 inspector 列（含空态占位）；off 图右栏收起。空态占位（`PanelEmptyState`）须在（tasks.md 2.4）。
> 拖动平滑/不闪 **CLI 验不了**，归入 Task 6 用户实测。

- [ ] **Step 6: Commit**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift
git commit -m "feat(3col): 右栏改 .inspector 系统检视列，删自绘右栏 resize

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
并在 `openspec/changes/workspace-3col-layout/tasks.md` 勾选 2.1 / 2.2 / 2.4，以及 2.3 中「WorkspaceDetailRegion 右栏部分 / rightWidth」部分（`PanelResizeHandle.swift` 删除留待 Task 5 勾完整 2.3）。

---

## Task 3: 下栏移到 split 外层全宽 `.safeAreaInset(.bottom)`（压所有）

> 对应 tasks.md 3.1 / 3.2 / 3.3。design D2 + D3。把下栏从 detail 区内 VStack 移到整个 `split` 外层全宽 safeAreaInset，使其横跨左+中+右、把整个 split 上推；detail 最终只剩 `content.inspector(...)`（不再被 VStack 包 → inspector 拖动彻底无 VStack 干扰，design D3 闭环）。

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（`body`、`detail`）

- [ ] **Step 1: detail 去掉 VStack/下栏，只留中栏 inspector**

把 Task 2 的 `detail` 收窄为：

```swift
// detail 只剩中栏内容 + 右栏 inspector；下栏移到 body 外层全宽（Step 2）。
// 关键（design D3）：detail/inspector 不再被任何 VStack 包裹 → inspector 拖动恢复。
private var detail: some View {
    content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: $showRightPanel) {
            RightPanelView()
                .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                      ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                      max: WorkspaceMetrics.rightPanelMaxWidth)
        }
        .toolbar(removing: .sidebarToggle)
}
```
> `.toolbar(removing: .sidebarToggle)` 原在 `split` 的 `detail:` 闭包里调（见现状 `RootSplitView.swift:152-153`）。挪进来或留在 `split` 闭包均可，保持一处即可，别重复。

- [ ] **Step 2: body 在 split 外层挂全宽下栏 safeAreaInset（与顶栏对称）**

把 `body` 改为在 `split` 上同时挂底部全宽下栏与顶部工具栏（下栏在 `.safeAreaInset(edge:.bottom)`，与顶栏 `.safeAreaInset(edge:.top)` 对称；**不 VStack 包裹 split**）：

```swift
@State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

var body: some View {
    split
        // 摘要悬浮浮层（保留，见 Task 4.2 不回归）。放在 inset 之前，落在顶栏下方内容区。
        .overlay(alignment: .topTrailing) {
            if showSummary {
                SummaryPopoverView(state: activeConversation.state, thread: selectedThread)
                    .frame(width: 340)
                    .frame(maxHeight: 480)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 下栏：全宽外层 safeAreaInset，横跨左+中+右、把 split 整体上推（design D2）。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showBottomPanel {
                VStack(spacing: 0) {
                    Divider()
                    BottomPanelView(height: $bottomHeight)
                }
            }
        }
        // 顶栏（保留，原样）。
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
            }
        }
        .environment(activeConversation)
}
```
> `showBottomPanel.toggle()` 已在顶栏「下面板」按钮里（现状 `RootSplitView.swift:92-94`），无需改——它现在驱动外层全宽下栏（tasks.md 3.3 满足）。`BottomPanelView` 与 `bottomHeight` 拖高/最小高/橙把手逻辑原样复用（tasks.md 3.2 的「可拖改高 + 最小高 + 自绘把手 hover/拖动变橙」由 `BottomPanelView.swift` 提供，不改）。

- [ ] **Step 3: 编译验证**

Run:
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 模拟器自检下栏全宽压所有（截图，静态可验）**

Run:
```bash
xcrun simctl install iPad-Test "$(find DerivedData -name CodexRemote.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch iPad-Test com.tangyujie.codexremote
# 打开下栏（顶栏下面板按钮）后截图
xcrun simctl io iPad-Test screenshot /tmp/3col-bottom-on.png
# 同时开右栏 inspector，验证下栏压住左+中+右（含左 sidebar）
xcrun simctl io iPad-Test screenshot /tmp/3col-all-open.png
```
Expected:
- `/tmp/3col-bottom-on.png`：下栏全宽横跨整屏底部，**含压住左 sidebar 区**（不再只压中+右）。
- `/tmp/3col-all-open.png`：上半部「左 sidebar · 中对话 · 右 inspector」三栏水平排布，下半部全宽下栏（spec.md「横屏五窗口同时可见」+「下边栏全宽压所有」）。
> 下栏拖高跟手 **CLI 验不了** → Task 6 用户实测。

- [ ] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift
git commit -m "feat(3col): 下栏移到 split 外层全宽 safeAreaInset，压左+中+右

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
勾选 tasks.md 3.1 / 3.2 / 3.3。

---

## Task 4: 删 `resizedRightWidth` 纯函数 + 修连带单测（保单测不破）

> 对应 tasks.md 2.3「WorkspaceMetrics.resizedRightWidth」+ 5.1「既有单测不破」。design D1/§4。右栏宽改由系统 `.inspectorColumnWidth` 托管，`resizedRightWidth` 自绘计算无人调用，删之；同时删引用它的 4 个测试（否则编译失败）。**保留宽度常量**（`.inspectorColumnWidth` 用）与高度常量/`clamp`（下栏用）。

**Files:**
- Modify: `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift`
- Test: `ios/CodexRemoteTests/WorkspaceMetricsTests.swift`

- [ ] **Step 1: 先跑一次现有测试确认基线绿**

Run:（测试/构建命令）
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** TEST SUCCEEDED **`（基线）。

- [ ] **Step 2: 从 `WorkspaceMetrics.swift` 删除 `resizedRightWidth`**

删掉这一整段（现状 `WorkspaceMetrics.swift:19-24`）：
```swift
    /// 右栏自绘拖动：把手在右栏左缘，向左拖（dragX<0）增宽、向右拖减宽，
    /// 结果夹到 [rightPanelMinWidth, rightPanelMaxWidth]。
    /// （取代 `.inspector` 内建 resize——后者在三栏全开时不可靠。）
    static func resizedRightWidth(current: CGFloat, dragX: CGFloat) -> CGFloat {
        clamp(current - dragX, min: rightPanelMinWidth, max: rightPanelMaxWidth)
    }
```
顺手把 `rightPanelMinWidth/IdealWidth/MaxWidth` 的注释从「自绘可拖列」改为「供 `.inspectorColumnWidth`」。**保留**三个宽度常量、两个高度常量、`clamp`。

- [ ] **Step 3: 从 `WorkspaceMetricsTests.swift` 删除引用 `resizedRightWidth` 的 4 个测试**

删掉这 4 个测试方法（现状 `WorkspaceMetricsTests.swift:22-36`）：`testResizedRightWidthDragLeftIncreasesWidth`、`testResizedRightWidthDragRightDecreasesWidth`、`testResizedRightWidthClampsToMax`、`testResizedRightWidthClampsToMin`。
保留 clamp / 常量正数的 5 个测试（它们仍验证下栏与 inspector 用到的常量/clamp）。

- [ ] **Step 4: 跑测试验证仍绿**

Run:
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** TEST SUCCEEDED **`（剩余测试全过，无「cannot find resizedRightWidth」编译错）。

- [ ] **Step 5: Commit**

```bash
git add ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift ios/CodexRemoteTests/WorkspaceMetricsTests.swift
git commit -m "refactor(3col): 删 resizedRightWidth 自绘逻辑及其单测（右栏宽改系统托管）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
勾选 tasks.md 5.1；并补勾 2.3 中 `resizedRightWidth` 部分（`PanelResizeHandle.swift` 删除在 Task 5 后整条 2.3 才算完成）。

---

## Task 5: 删除 `PanelResizeHandle.swift`（仅右栏用，已被 inspector 取代）

> 对应 tasks.md 2.3「PanelResizeHandle(右栏用法)」。design D1。该文件仅供右栏左缘自绘拖把手；右栏已改 inspector，文件无人引用，整文件删除。

**Files:**
- Delete: `ios/CodexRemote/Views/Workspace/PanelResizeHandle.swift`

- [ ] **Step 1: 确认无引用**

Run:
```bash
grep -rn "PanelResizeHandle" ios --include="*.swift"
```
Expected: 无输出（Task 2 已从 `RootSplitView` 移除调用）。若仍有命中，回 Task 2 清干净再继续。

- [ ] **Step 2: 删除文件**

Run: `git rm ios/CodexRemote/Views/Workspace/PanelResizeHandle.swift`

- [ ] **Step 3: 编译验证（xcodegen 按目录收文件，删后自动不再编译）**

Run:
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** BUILD SUCCEEDED **`。若报 `PanelResizeHandle.xcodeproj` 引用残留，在 `ios/` 下 `xcodegen generate` 重生工程后重试。

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(3col): 删除 PanelResizeHandle（右栏 resize 已由 .inspector 取代）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
勾选 tasks.md 2.3（整条完成）。

---

## Task 6: 不回归全量自检 + 用户实测验收

> 对应 tasks.md 4.1–4.5 / 5.2 / 5.3 / 5.4。design D4 + §4。截图能验「静态不回归」；拖动手感/不闪只能用户实测。

**Files:** 无（仅验证；如发现回归再回对应 Task 修）

- [ ] **Step 1: 跑全量单测**

Run:
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
```
Expected: `** TEST SUCCEEDED **`（含 `WorkspaceSummaryTests` 摘要派生不破——tasks.md 4.2 / 5.1）。

- [ ] **Step 2: 逐态截图自检（静态可验，tasks.md 5.2 + 4.x）**

装最新构建后，逐状态截图并逐项核对：
```bash
xcrun simctl install iPad-Test "$(find DerivedData -name CodexRemote.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch iPad-Test com.tangyujie.codexremote
xcrun simctl io iPad-Test screenshot /tmp/3col-final-allopen.png   # 右+下全开
xcrun simctl io iPad-Test screenshot /tmp/3col-final-summary.png   # 点摘要(:≡)按钮后
xcrun simctl io iPad-Test screenshot /tmp/3col-final-leftoff.png   # 收左栏后（右栏不受影响）
```
核对清单（对照 design D4 + spec.md「不回归」）：
- [ ] 顶栏工具栏 5 按钮（左/下/摘要/右/设置）在位；右按钮切 inspector 显隐生效（tasks.md 4.1）。
- [ ] 摘要 `:≡` 浮层正常浮现、内容（P0 数据）在（tasks.md 4.2）。
- [ ] 橙 `AccentColor` 主题：下栏把手/左把手 hover 或拖动态为橙（tasks.md 4.3）。
- [ ] 左栏选中态自渲染、左把手宽度监听高亮在（tasks.md 4.3）。
- [ ] `SettingsMenu` 与 composer 模型选择 `.popover` 能弹（tasks.md 4.4）。
- [ ] 右栏 / 下栏空态占位（`PanelEmptyState`）在（tasks.md 4.5）。
- [ ] 收起左 sidebar 时右栏 inspector 仍在、可独立显隐（spec.md「不受左边栏显隐影响」）。

- [ ] **Step 3: 暂停 → 用户实测验收（CLI 验不了，tasks.md 5.3）**

把全部截图附报告，请用户在模拟器/真机实测并回报：
1. 右栏 inspector 拖动**平滑不闪**（对照左 sidebar）——本 change 核心目标。
2. 下栏拖高**跟手**、不小于最小高。
3. detail/inspector 列可拖宽（三栏全开时）。
失败则回对应 Task（或 design §3 退路）处理，不擅自标完成。

- [ ] **Step 4: 真机验收延期登记（tasks.md 5.4）**

真机 E2E 沿用 v1/change1 延期约定，列为 follow-up，不在本计划内执行。在报告中注明「真机延期」。

- [ ] **Step 5: 勾选验证项 + 收尾**

用户回报通过后，勾选 tasks.md 4.1–4.5 / 5.2 / 5.3（5.4 标延期）。无代码改动则无需 commit；若 Step 2/3 发现回归并修了，按所属 Task 的提交格式补 commit。

> 本计划全部 Task 完成后，进入 comet `verify` 阶段（`comet-verify`）。

---

## 自检（writing-plans 收尾）

**1. spec 覆盖：**
- spec「下边栏全宽压所有 / 横屏五窗口同屏」→ Task 3。
- spec「右边栏系统检视列、平滑不闪、不受左栏显隐影响」→ Task 1（前提）+ Task 2 + Task 6 Step 3。
- spec「右/下栏空态占位、最小尺寸」→ Task 2 Step 5（右空态/inspectorColumnWidth min）+ Task 3（下栏复用 BottomPanelView 最小高）+ Task 6 Step 2。
- tasks.md 全条目均有对应 Task（1.1→T1；2.1/2.2/2.4→T2，2.3→T2+T4+T5；3.x→T3；4.x/5.x→T6，5.1 单测→T4+T6）。
- design D1/D2/D3/D4 全覆盖；§3 风险 spike=T1 且含退路暂停点；§4 测试策略（单测不破/截图/实测/真机延期）贯穿 T4/T6。

**2. 占位扫描：** 无 TBD/「适当处理」类占位；每个改码步骤均给出完整 SwiftUI 代码块与确切文件/行引用。

**3. 类型/签名一致：** `showRightPanel`/`showBottomPanel`/`bottomHeight`/`WorkspaceMetrics.rightPanelMinWidth|IdealWidth|MaxWidth`/`bottomPanelIdealHeight`/`RightPanelView`/`BottomPanelView`/`SummaryPopoverView` 全程与现状代码命名一致；删除符号 `resizedRightWidth`、`PanelResizeHandle`、`WorkspaceDetailRegion`、`rightWidth`、`rightDragBase` 在删除后不再被任何后续 Task 引用。

> **注意（base-ref 一致性）：** 本计划 frontmatter `base-ref: addd34718a029d9908f4cd55e5cf8dd12a130ed2`（按用户指令固定）。`.comet.yaml` 记录的 `base_ref` 为 `c83407a98568...`，二者不一致——执行前请向用户确认以哪个为准（不影响任务内容，仅影响分支基线）。
