---
comet_change: ipad-workspace-shell
role: technical-design
canonical_spec: openspec
---

# iPad CodexRemote 五窗口工作区骨架 — 技术设计

> OpenSpec delta spec 是规范事实源（`openspec/changes/ipad-workspace-shell/specs/`）。本文档描述 HOW；WHAT/验收以 delta spec 为准。

## 1. Context

v1 已交付固定顶栏 + 三栏 + 占列 inspector。本期把布局升级为复刻 Codex desktop 的**五窗口工作区**：左边栏 · 中间 · 右边栏(整列) · 下边栏 · 摘要(悬浮浮层)。本期只搭**骨架**——右/下栏占位（空态 + 可拖 + 最小尺寸 + toggle），真实内容（Diff/文件/终端）各自后续 change。仅改 UI 布局层。

## 2. 布局层级（关键）

```
┌─────────┬───────────────────────────┐
│         │  中间(对话) │ 右栏(inspector) │ ← 被下栏压短
│  左边栏  │─────────────────────────── │
│ (满高)   │      下边栏(横跨中间+右栏)    │ ← 不伸到左边栏下
└─────────┴───────────────────────────┘
```

- **左边栏**：NavigationSplitView 的 sidebar 列，**满高**，不被下栏压短。
- **detail 区**（左边栏右侧的一切）：一个 **VStack** —— 上半 = 中间对话 + 右栏 `.inspector`；下半 = 下边栏。下边栏在 detail 区内部，故只压短中间+右栏，不伸到左边栏底下。

## 3. Decisions

### D1：顶栏 = `.safeAreaInset(edge:.top)`
固定全局工具栏挂在 NavigationSplitView 上（**不用 VStack 包整个 split**——v1 已证那会破坏 `.inspector` 拖动）。按钮左→右：左面板 / 下面板 / 右面板 / 摘要(`:≡`) / 设置（去前进后退）。规避 v1 坑：不叠加系统 `sidebarToggle`（折叠时消失/与显式开关重复），侧栏显隐由顶栏"左面板"按钮显式控制 `columnVisibility`。

### D2：摘要 = `.popover(isPresented:)`
`:≡` 按钮触发的 SwiftUI popover（iPad 上为悬浮气泡、内容自适应，"有多少显多少"）。P0 内容与数据源：
- diff 行数统计：`turn/diff/updated`（端侧解析 unified diff 数 +/- 行）
- cwd：`Thread.cwd`
- 进度：`turn/plan/updated` → `TurnPlanStep{step,status}`（status: pending/inProgress/completed → 勾选圈）
- 任务：会话内 `commandExecution` items（命令列表）
无数据时显空态占位。

### D3：右栏 = `.inspector(isPresented:)`
可显隐 + 原生可拖 + 最小宽（`.inspectorColumnWidth(min:ideal:max:)`）；配 D1 的 safeAreaInset 顶栏（v1 证选中对话时可拖）。本期空态占位（"右面板"按钮 toggle）；后续 change 往里填 Diff/文件/终端 等 tab。

### D4：下栏 = detail 区内 VStack 分割
detail = `VStack { 上半(中间+右栏) ; Divider(可拖) ; 下栏 }`。可拖 Divider 调高 + 最小高（`GeometryReader`/`@State` 高度 + clamp 到最小值）。下栏在 detail 区内 → 横跨中间+右栏、不伸到左边栏。本期空态占位（"下面板"按钮 toggle）；后续填终端。

### D5：面板统一框架
抽共享约定：空态视图（无内容占位）+ 最小尺寸常量（右栏最小宽 / 下栏最小高）+ toggle 状态（@State Bool）。右栏(inspector)与下栏(VStack)结构不同，不强求单一容器；共享空态视图 + 尺寸常量 + toggle 模式即可，后续 change 填内容时复用。

### D6：图标
顶栏 5 图标；摘要用已就绪的 Codex 真实 panel-right SVG（`InspectorClosed`/`InspectorOpen` 资产，描边=关/填充=开）；左/下/右面板用对应 SF Symbol（`sidebar.leading` / 底部面板 / 右面板）。

## 4. 测试策略

- **单测**：diff 行数计算、plan 归约（plan steps → 进度项）、摘要 P0 派生逻辑、面板最小尺寸 clamp、toggle 状态。
- **模拟器逐态自检**（截图）：顶栏 5 按钮、摘要浮层显隐、右/下栏空态、布局层级（左栏满高、下栏压短中间+右栏）。
- **拖动手势**：CLI 截图验不了 → UI 测试或用户确认（v1 教训）。
- **真机**：follow-up（沿用 v1 延期）。

## 5. Risks / Non-Goals

- 风险：多面板 + 浮层 + 拖动与 v1 inspector 拖动坑同源——逐态模拟器自检 + 规避 VStack 包 split / 系统 sidebarToggle。
- 非目标：右/下栏真实内容（Diff/文件/终端/编辑器/预览 → 后续 change）；浏览器（Electron webview 拿不到）；提交推送/PR 状态（desktop 本地）；真机 E2E（follow-up）。

## 6. Implementation Divergence（实现偏差，verify 阶段补记）

build 阶段经多轮用户反馈，实际实现偏离了 §3 的部分设计决策。如实记录如下（不阻塞归档；右栏 resize 的根本重构由后续 change 承接）：

- **D2 摘要**：设计为 `.popover` 锚定 `:≡` 按钮；实际改为 **`.overlay(alignment:.topTrailing)` 常驻悬浮浮层**（点击别处不收回，仅由摘要按钮显隐；放在 safeAreaInset 之前以落在顶栏下方不遮挡按钮）。
- **D3 右栏**：设计为 `.inspector(isPresented:)` + `.inspectorColumnWidth`；实际改为 **HStack 内自绘可拖列**（`PanelResizeHandle` + `WorkspaceMetrics.resizedRightWidth`）。原因：`.inspector` 内建 resize 在三栏全开时不可靠。**已知限制**：自绘横向 resize 在拖动时中栏 ScrollView 随宽度重排导致**闪屏**，多次尝试（commit-on-release / 状态隔离到 WorkspaceDetailRegion / 移除 .transition）未根治 → 用户决定**新开 change 用三列 NavigationSplitView 系统列重构取代**（右栏改系统第三列消闪 + 下栏改全宽 safeAreaInset 覆盖左右）。
- **D6 图标**：摘要图标最终用 **`list.bullet`**（:≡ 两圆点两横线），非 Codex panel-right SVG（后者是 inspector 图标，被误指给摘要，已纠正）。三个面板图标统一 `rectangle.*.inset.filled` 族。
- **新增（design doc 未预先记录，build 内反馈轮）**：
  - 全局主题色：定义橙铜 `AccentColor`（深浅两态）+ `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`，去除系统蓝（选择性用橙：选中/主操作/链接用橙，chrome 中性）。
  - 左栏选中态自渲染（左缘橙条 + 橙标题，弃用系统 List 方框，收起重开不丢）。
  - 三处拖动把手（左/右/下）hover 或拖动中变橙；左把手用宽度监听点亮（系统列钩不到拖动事件）。
  - `SettingsMenu` + composer 模型选择由 `Menu` 改 `.popover`（不遮挡按钮、不闪现）。
- **布局行为后续变更**（移交新 change）：原 §1「下栏不压左栏」将改为「下栏全宽、压所有（含左栏）、最高优先级」。
