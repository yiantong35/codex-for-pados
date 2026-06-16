# Comet Design Handoff

- Change: workspace-3col-layout
- Phase: design
- Mode: compact
- Context hash: 8e2976750a23122d608015599ec36189639e0ecd54ddad5ca6d2cd5d39c1dfc7

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/workspace-3col-layout/proposal.md

- Source: openspec/changes/workspace-3col-layout/proposal.md
- Lines: 1-34
- SHA256: 7a98614196a9da10edaecea2aadb1dca343ceb1c3faa23a7a8b5317c5be4b0aa

```md
# Proposal: 三列系统列布局重构（workspace-3col-layout）

## Why（问题背景）

`ipad-workspace-shell`（已交付）把右边栏做成**自绘 HStack 可拖列**（`PanelResizeHandle` + `@State` 宽度）。但拖动右栏把手时**严重闪屏**：中栏对话 ScrollView 随宽度每帧重排、右栏面板重绘。多次尝试均未根治（commit-on-release / 状态隔离到子视图 / 移除 `.transition`）——这是自绘横向 split 的固有问题。

对照印证：**左边栏是 `NavigationSplitView` 的系统列,拖动平滑不闪**;下边栏是自绘纵向拖,最跟手。差异在于右栏是"自绘横向 resize + body 重跑 + 内容重排"三者叠加。

## What（目标 + 范围）

把右边栏从自绘列改为**系统管理的列**(复用左栏同款机制),从根本上消除闪屏并统一三栏 resize 体验。

### 目标
- 右栏拖动**平滑不闪**(对照左栏体验)。
- 三栏 resize 机制统一(都走系统/平滑路径)。
- 既有能力零回归(摘要 overlay、橙主题、选中自渲染、把手高亮、Menu→popover、面板 toggle)。

### 方案要点
- **右栏 → `.inspector` 系统检视列**(右侧系统列,左 sidebar 的镜像):系统托管 resize(平滑不闪)+ 可显隐 + 最小宽。不用 NavigationSplitView detail 第三列(它不能显隐)。关键:不 VStack 包 detail(旧 inspector 拖不动的根因)。
- **下栏 → 全宽 `.safeAreaInset(edge:.bottom)`** 挂在三栏 split 外层(像顶栏那样,不用 VStack 包裹以免破坏系统列拖动):横跨左+中+右全宽,把整个 split 往上压。
- **布局行为翻转**:由「下边栏不压左边栏」改为「**下边栏全宽、压所有(含左边栏)、最高优先级**」。

### 范围边界
- 仅改 `RootSplitView` 布局骨架(右栏 resize 机制、下栏位置与压缩行为)及其直接配套(把手/尺寸状态)。
- 保留并不回归:摘要悬浮浮层、橙 AccentColor 主题、左栏选中态自渲染、左把手宽度监听高亮、`SettingsMenu`/composer 模型选择的 `.popover`、顶栏 safeAreaInset 工具栏、各面板 toggle 与空态。

## Non-Goals（非目标）
- 右/下栏**真实内容**(Diff/文件/终端等)——各自后续 change。
- **sidebar 状态徽标**——下一个独立 change(可行性已调查)。
- 真机 E2E——follow-up(沿用 v1/change1 延期约定)。

## 关键未知 / 风险
- **不被 VStack 包裹的 `.inspector` 在三栏全开时拖动是否正常+不闪**——预期正常(inspector 是系统机制,旧失败根因=被 VStack 包)。构建第一步快速 spike 确认;若仍异常,暂停与用户议退路(保留自绘但换消闪手段 / 固定宽 toggle-only)。
- inspector + 全宽 safeAreaInset 下栏 + 顶栏 safeAreaInset 的组合是否破坏拖动——沿用 change1 教训(不 VStack 包裹 split)。
```

## openspec/changes/workspace-3col-layout/design.md

- Source: openspec/changes/workspace-3col-layout/design.md
- Lines: 1-39
- SHA256: 4ef4fb4e252804ad1252aba116fc5659e1d8d522e9db5eedc84bbfe667731980

```md
# Design（高层）: 三列系统列布局重构

> 高层架构决策。深度技术设计 + 风险/测试细节由 comet-design 阶段的 Design Doc 承接。

## 架构决策

### A1：右栏 = `.inspector` 系统检视列
现状 `NavigationSplitView { sidebar } detail: { HStack{中栏 | 自绘把手 | 右栏} }` →
改为 `NavigationSplitView { sidebar } detail: { 中栏对话.inspector(isPresented:$showRightPanel){ RightPanelView } }`。
- inspector 是 SwiftUI 给「右侧」的系统列（左 sidebar 的镜像）：系统托管 resize（平滑不闪）+ 可显隐 + 最小宽。
- 为何不用 NavigationSplitView detail 第三列：detail 列不能显隐（columnVisibility 只控左侧列），右栏要 toggle → 用 inspector。
- 宽度：`.inspectorColumnWidth(min:ideal:max:)`（沿用 WorkspaceMetrics 常量）。显隐：`showRightPanel` 绑 `isPresented`。
- 去掉 `PanelResizeHandle`(右用法)/`rightWidth @State`/`WorkspaceDetailRegion` 右栏自绘逻辑。
- **关键：不 VStack 包 detail**（旧 inspector 拖不动的根因）。下栏改全宽外层 safeAreaInset（A2）后，inspector 不被包裹 → 拖动恢复 + 系统托管不闪。
- **前提验证（构建第一步 spike）**：不被 VStack 包的 inspector，三栏全开时拖动是否正常+不闪。异常 → 暂停议退路。

### A2：下栏 = 全宽 safeAreaInset(.bottom)
下栏从「detail 区内 VStack 分割（压中+右）」改为「整个 split 外层 `.safeAreaInset(edge:.bottom)`」：
- 全宽横跨左+中+右，把整个三栏 split 往上压（**布局翻转：压所有，含左栏**）。
- 不用 VStack 包裹 split（沿用 change1 教训，避免破坏系统列拖动）；与顶栏 `.safeAreaInset(.top)` 对称。
- 下栏仍自绘纵向拖把手（`BottomPanelView`，最跟手），保留 hover/拖动变橙。

### A3：保留项（不回归）
- 顶栏 `.safeAreaInset(.top)` 工具栏（左/下/摘要/右/设置）；右面板按钮改为切 `columnVisibility` 的 detail 显隐。
- 摘要 `.overlay` 常驻浮层 + P0 数据。
- 橙 `AccentColor` 主题、左栏选中态自渲染、左把手宽度监听高亮。
- `SettingsMenu` + composer 模型选择 `.popover`。
- 右/下栏空态占位 + 最小尺寸。

### A4：图标与 toggle
- 右面板按钮 toggle detail 列显隐；下面板按钮 toggle 全宽下栏显隐；其余不变。

## 数据流
纯 UI 布局层，无新增协议/数据流。右栏宽度由系统列托管（不再 `@State`）；下栏高度仍 `@State`（`bottomHeight` + clamp）。

## 测试策略（高层）
- 单测：下栏高度 clamp（已有 `WorkspaceMetrics`）；摘要派生逻辑（已有，不回归）。
- 模拟器逐态自检（截图）：三列同屏、下栏全宽覆盖左右、各面板空态/显隐、主题/选中不回归。
- 拖动平滑/手势：CLI 验不了 → 用户真机/模拟器确认（右栏是否还闪、下栏拖高、detail 列可否拖宽）。
```

## openspec/changes/workspace-3col-layout/tasks.md

- Source: openspec/changes/workspace-3col-layout/tasks.md
- Lines: 1-28
- SHA256: cf7a075a33d1726b01532c2a1ea018db50fa3df3cfa1ab3bea4742bc76a46901

```md
# Tasks: 三列系统列布局重构

## 1. 前提验证（构建第一步，阻塞）
- [ ] 1.1 spike 验证：不被 VStack 包裹的 `.inspector(isPresented:)` 在三栏全开时拖动正常+不闪（中栏对话 .inspector{占位}，模拟器/真机试拖）。正常 → 继续；异常 → 暂停与用户议退路

## 2. 右栏改 `.inspector` 系统检视列
- [ ] 2.1 `RootSplitView`：中栏对话 `.inspector(isPresented:$showRightPanel){ RightPanelView }` + `.inspectorColumnWidth(min/ideal/max)`（沿用 WorkspaceMetrics 常量）
- [ ] 2.2 右面板按钮 toggle `showRightPanel`（绑 inspector isPresented）
- [ ] 2.3 移除自绘右栏 resize：`PanelResizeHandle`(右栏用法)、`rightWidth`/`WorkspaceMetrics.resizedRightWidth`、`WorkspaceDetailRegion` 右栏部分
- [ ] 2.4 右栏最小宽 + 空态占位保留（inspectorColumnWidth + RightPanelView 空态）

## 3. 下栏改全宽外层 safeAreaInset
- [ ] 3.1 下栏从 detail 区内移到整个 split 外层 `.safeAreaInset(edge:.bottom)`（不 VStack 包裹）
- [ ] 3.2 下栏全宽覆盖左+中+右、压所有（布局翻转）；保留可拖改高 + 最小高 + 自绘把手 hover/拖动变橙
- [ ] 3.3 下面板按钮 toggle 全宽下栏显隐

## 4. 不回归既有能力
- [ ] 4.1 顶栏 safeAreaInset 工具栏（左/下/摘要/右/设置）正常，右按钮切 detail 显隐
- [ ] 4.2 摘要 overlay 浮层 + P0 数据不回归
- [ ] 4.3 橙 AccentColor 主题、左栏选中态自渲染、左把手宽度监听高亮不回归
- [ ] 4.4 SettingsMenu + composer 模型选择 `.popover` 不回归
- [ ] 4.5 各面板空态占位不回归

## 5. 验证
- [ ] 5.1 单测通过（下栏高度 clamp、摘要派生逻辑等既有测试不破）
- [ ] 5.2 模拟器逐态自检（截图）：三列同屏、下栏全宽覆盖左右、显隐组合、主题/选中不回归
- [ ] 5.3 用户实测确认：右栏拖动平滑不闪（对照左栏）、下栏拖高跟手、detail 列可拖宽
- [ ] 5.4 真机验收（follow-up，沿用 v1/change1 延期约定）
```

## openspec/changes/workspace-3col-layout/specs/workspace-layout/spec.md

- Source: openspec/changes/workspace-3col-layout/specs/workspace-layout/spec.md
- Lines: 1-49
- SHA256: 01824b6eccaf238659e5ba520d01ebeae591ab79cdeafe7d6f7447d5cee9664a

```md
## MODIFIED Requirements

### Requirement: 五窗口工作区布局与层级
iPad 客户端 SHALL 提供复刻 Codex desktop 的五窗口工作区：左边栏（项目/对话）· 中间（对话）· 右边栏（整列）· 下边栏 · 摘要（悬浮浮层）。布局层级（**本 change 翻转**）：左边栏 · 中间 · 右边栏三者为水平排布；**下边栏为全宽、最高优先级，横跨并压短左边栏 + 中间 + 右边栏全部**（不再让左边栏满高不被压）。

> 变更说明：change `ipad-workspace-shell` 原定「下边栏不压左边栏、只压中+右」。本 change 因右边栏改为系统列（见下），下边栏移到三栏 split 外层做全宽，故层级改为「下边栏压所有（含左边栏）」。

#### Scenario: 下边栏全宽压所有
- **WHEN** 下边栏处于打开状态
- **THEN** 下边栏全宽横跨左边栏 + 中间 + 右边栏，并将三者整体纵向压短
- **AND** 下边栏始终在最底部、最高优先级

#### Scenario: 横屏五窗口同时可见
- **WHEN** 横屏且右边栏、下边栏均打开
- **THEN** 上半部左边栏 · 中间 · 右边栏 同屏水平排布，下半部为全宽下边栏

### Requirement: 右边栏可显隐整列面板
iPad 客户端 SHALL 提供右边栏整列面板，支持显隐切换、可拖拽改宽、最小宽度；本期内容为占位空态（真实内容由后续 change 提供）。右边栏 SHALL 由系统检视列（`.inspector`，右侧系统列、左侧 sidebar 的镜像）托管，拖拽改宽平滑无闪屏，且不受左边栏显隐影响。

> 变更说明：原 change 用自绘 HStack 列 + `PanelResizeHandle`，拖动闪屏。本 change 改为系统检视列 `.inspector(isPresented:)` + `.inspectorColumnWidth`，由系统托管 resize（不闪）。NavigationSplitView 的 detail 第三列不能显隐，故右栏用 inspector 而非 detail 列。旧 inspector 拖不动的根因是 detail 被 VStack 包裹（塞下栏），本 change 下栏改全宽外层 safeAreaInset、不再 VStack 包 split，inspector 拖动恢复。

#### Scenario: 右边栏显隐与拖动
- **WHEN** 用户切换右面板按钮
- **THEN** 右边栏整列在显示与隐藏间切换
- **AND** 显示时可拖拽改宽，且不小于最小宽度
- **AND** 拖动改宽平滑、无闪屏（与左边栏一致），不受左边栏显隐影响

#### Scenario: 右边栏空态占位
- **WHEN** 右边栏打开且本期无真实内容
- **THEN** 显示空态占位

### Requirement: 下边栏可显隐底部面板
iPad 客户端 SHALL 提供下边栏底部面板，支持显隐切换、可拖拽改高、最小高度；本期内容为占位空态（终端等真实内容由后续 change 提供）。下边栏 SHALL 为全宽、挂在三栏布局外层（最高优先级），覆盖并压短左+中+右；其拖拽改高自绘、跟手、无闪屏。

> 变更说明：原 change 下边栏在 detail 区内只压中+右。本 change 改为外层全宽 safeAreaInset，压所有。

#### Scenario: 下边栏显隐与拖动
- **WHEN** 用户切换下面板按钮
- **THEN** 下边栏在显示与隐藏间切换
- **AND** 显示时可拖拽改高，且不小于最小高度
- **AND** 拖动改高跟手、无闪屏

#### Scenario: 下边栏全宽覆盖
- **WHEN** 下边栏打开
- **THEN** 下边栏全宽横跨左+中+右，不留任何一栏在其侧边

#### Scenario: 下边栏空态占位
- **WHEN** 下边栏打开且本期无真实内容
- **THEN** 显示空态占位
```

