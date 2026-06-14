---
comet_change: workspace-3col-layout
role: technical-design
canonical_spec: openspec
---

# Design Doc: 三列系统列布局重构（workspace-3col-layout）

## 1. 背景与目标

`ipad-workspace-shell` 右栏用自绘 HStack 列（`PanelResizeHandle` + `@State rightWidth`），拖动时中栏对话 ScrollView 随宽度每帧重排 + 右栏重绘 → **闪屏**。多次修复（commit-on-release / 状态隔离 / 去 `.transition`）未根治，是自绘横向 resize 的固有问题。

对照：左栏（NavigationSplitView 系统 sidebar 列）系统托管 resize、平滑不闪；下栏（自绘纵向拖）最跟手。

**目标**：右栏改用系统托管列 → 消闪；下栏改全宽外层 safeAreaInset → 覆盖左+中+右；既有能力零回归。

## 2. 核心架构决策

### D1：右栏 = `.inspector` 系统检视列

```
NavigationSplitView(columnVisibility: $columnVisibility) {
    SidebarView(...)            // 左：系统 sidebar 列（可隐可拖，已有）
} detail: {
    content                     // 中：ConversationView / 空态
        .inspector(isPresented: $showRightPanel) {   // 右：系统检视列
            RightPanelView()
                .inspectorColumnWidth(min: rightPanelMinWidth,
                                      ideal: rightPanelIdealWidth,
                                      max: rightPanelMaxWidth)
        }
}
```

- **inspector 是右侧的系统列**（左 sidebar 的镜像）：系统托管 resize（不闪）+ 可显隐（`isPresented`）+ 最小宽。
- **为何不用 detail 第三列**：NavigationSplitView 不对称——`columnVisibility` 只能收起左侧列（sidebar/content），detail 第三列不能显隐。右栏要 toggle → 用 inspector。
- **移除**：`PanelResizeHandle`（右栏用法）、`rightWidth`/`rightDragBase` `@State`、`WorkspaceMetrics.resizedRightWidth`、`WorkspaceDetailRegion` 的右栏 HStack/把手部分。
- 右面板按钮：`showRightPanel.toggle()` 绑 inspector `isPresented`。

### D2：下栏 = 全宽外层 `.safeAreaInset(.bottom)`

下栏从「detail 区内 VStack 分割（压中+右）」改为「整个 split 外层 `.safeAreaInset(edge:.bottom)`」：

```
split
    .safeAreaInset(edge: .bottom) { if showBottomPanel { BottomPanelView(height: $bottomHeight) } }
    .safeAreaInset(edge: .top)    { topBar }      // 已有
    .overlay(alignment: .topTrailing) { 摘要浮层 } // 已有
```

- **全宽**横跨左+中+右；**compress 上推**（把整个 split 纵向压短，非 overlay）。
- 与顶栏 `.safeAreaInset(.top)` 对称；**不 VStack 包裹 split**。
- 布局翻转：由「下栏不压左栏」→「**下栏压所有（含左栏）、最高优先级**」。
- `BottomPanelView` 不变：自绘纵向拖把手 + hover/拖动变橙 + 最小高 clamp（`bottomHeight @State` 留在 RootSplitView 或其子）。

### D3：旧 inspector 拖不动的根因 = VStack 包裹（本 change 消除）

v1/change1 曾因「为塞下栏把 detail 用 `VStack{ 中栏.inspector ; 下栏 }` 包起来」导致 inspector 拖动失效（记于 v1 教训）。本 change 下栏移到外层全宽 safeAreaInset → **detail/inspector 不再被 VStack 包** → 拖动恢复。这把「消闪（系统托管）」与「inspector 可拖」一并解决，是本 change 的关键洞察。

### D4：保留不回归

顶栏 safeAreaInset 工具栏（右按钮切 inspector 显隐）、摘要 overlay + P0、橙 `AccentColor`、左栏选中态自渲染、左把手宽度监听高亮、`SettingsMenu`/composer 模型选择 `.popover`、右/下栏空态占位与最小尺寸。

## 3. 风险与退路

- **最高风险**：不被 VStack 包的 inspector 在三栏全开（左栏开）时拖动是否正常+不闪。
  - 预期正常（inspector 系统机制；旧失败根因已定位=VStack 包裹）。
  - **build 第一步 spike**（tasks 1.1）：最小复现——中栏 `.inspector{占位}` + 全宽 safeAreaInset 下栏，模拟器/真机试拖、观察是否闪。
  - 异常时退路（不预先锁定，spike 失败再议）：保留自绘列但换消闪手段（拖动中冻结对话快照 / 中栏改非 lazy）；或右栏固定宽 toggle-only（最简、绝对不闪）。
- 拖动平滑/手势 **CLI 验不了** → 靠用户模拟器/真机实测（右栏不闪、下栏拖高、inspector 可拖）。

## 4. 测试策略

- **单测**：既有不破（下栏高度 clamp `WorkspaceMetrics`、摘要派生 `WorkspaceSummary`）。无新增纯逻辑（右栏宽改由系统托管，无 `resizedRightWidth` 自绘逻辑）。
- **模拟器逐态截图自检**：inspector 显/隐、下栏全宽压所有、显隐组合、橙主题/选中自渲染/把手/popover 不回归。
- **用户实测**：右栏拖动平滑不闪（对照左栏）、下栏拖高跟手、inspector 可拖。
- **真机**：follow-up（沿用 v1/change1 延期）。

## 5. Non-Goals

右/下栏真实内容（Diff/文件/终端 → 后续 change）；sidebar 状态徽标（下一个独立 change）；真机 E2E（follow-up）。
