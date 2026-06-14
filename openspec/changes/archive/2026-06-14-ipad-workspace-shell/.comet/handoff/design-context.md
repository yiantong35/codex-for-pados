# Comet Design Handoff

- Change: ipad-workspace-shell
- Phase: design
- Mode: compact
- Context hash: 1c3e5e48fa803ffa3b4bf4d745bf49d092b0c24f39f13b1df6bb82fc0b3901e7

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/ipad-workspace-shell/proposal.md

- Source: openspec/changes/ipad-workspace-shell/proposal.md
- Lines: 1-25
- SHA256: 3a0c3a2df37a4089bb65a3b8ac681fce4500f4e3e7b9b1568a9e6987003f37db

```md
## Why

v1 把"环境信息"做成了占整列的 inspector，并配了错误图标；但 Codex desktop 的真实形态是**多窗口工作区**——摘要是悬浮浮层、右栏是可装多内容的整列、还有下栏终端。要在 iPad 上复刻 desktop 的工作区体验，需要先把这套**多窗口布局骨架**搭对：五个窗口、统一的顶栏开关、面板的显隐/拖动/最小尺寸/空态框架。这是后续 Diff / 文件 / 终端等面板的地基，必须先立。

## What Changes

- **新增多窗口布局骨架**：左边栏（项目/对话，已有）· 中间（对话，已有）· **右边栏**（整列占位）· **下边栏**（占位）· **摘要浮层**。
- **顶栏重排**（**BREAKING** v1 顶栏）：去掉前进/后退；按钮从左到右 = 左面板 · 下面板 · 右面板 · 摘要(`:≡`) · 设置。
- **摘要改悬浮浮层**：从 v1 的占列 inspector 改为 `:≡` 触发的悬浮浮层（内容自适应、非整列）；P0 内容 = diff 行数统计 / cwd / 进度(plan) / 任务(命令列表)。
- **右栏 / 下栏占位**：本期不做真实内容，但从一开始即支持 toggle 显隐 + 空态 + 可拖 + 最小尺寸（宽/高）。
- **inspector 图标**：改用从 Codex desktop 扒出的真实 panel-right SVG（描边/填充两态）。

## Capabilities

### New Capabilities
- `workspace-layout`: iPad 多窗口工作区骨架——五窗口布局、顶部固定全局工具栏（面板开关）、面板显隐/拖动/最小尺寸/空态框架、摘要悬浮浮层。

### Modified Capabilities
- `session-management`: v1 的"主界面布局可隐藏 inspector 且设置常显"需求被本期重做——inspector 占列改为摘要悬浮浮层；顶栏按钮重排；右/下栏纳入布局。

## Impact

- 代码：`ios/CodexRemote/Views/RootSplitView.swift`（重构为 5 窗口骨架）、新增摘要浮层视图 + 右栏/下栏占位视图、`Assets`（Codex SVG 图标已就绪）、本地化键。
- 不影响：连接层、归约层、审批层、会话数据层（仅 UI 布局层）。
- 非目标（后续 change / 拿不到）：右栏 Diff/文件/终端/编辑器/预览真实内容、浏览器、提交推送/PR 状态、真机 E2E（沿用 v1 follow-up）。
```

## openspec/changes/ipad-workspace-shell/design.md

- Source: openspec/changes/ipad-workspace-shell/design.md
- Lines: 1-28
- SHA256: c234849890b2bb01691ce1873b5b25c638c7ff7db7c5bccf852f120aca850869

```md
## Context

v1 已交付固定顶栏 + 三栏 + 占列 inspector。本期把布局升级为复刻 Codex desktop 的**五窗口工作区**，且把"摘要"从占列改为悬浮浮层。仅改 UI 布局层，不动连接/归约/审批/数据层。详细技术设计（浮层定位、拖动手柄、最小尺寸实现）在 design 阶段的 Superpowers Design Doc 展开；本文件只记高层决策。

## Goals

- 五窗口骨架：左边栏 · 中间 · 右边栏(整列占位) · 下边栏(占位) · 摘要(悬浮浮层)。
- 顶部固定全局工具栏：左面板 · 下面板 · 右面板 · 摘要(`:≡`) · 设置（去前进/后退）。
- 面板统一交互：按钮 toggle 显隐 + 空态 + 可拖 + 最小尺寸（右栏最小宽、下栏最小高）。
- 摘要浮层 P0 内容：diff 行数 / cwd / 进度(plan) / 任务(命令列表)。
- inspector 图标用 Codex 真实 panel-right SVG。

## Non-Goals

- 右栏/下栏真实内容（Diff/文件/终端/编辑器/预览）—— 各自后续 change。
- 浏览器（Electron webview，协议拿不到）；提交推送/PR 状态（desktop 本地 git/gh）。
- 真机 E2E（沿用 v1 follow-up）。

## High-level Decisions

- **D1 布局容器**：保留 v1 的固定顶栏方案（`.safeAreaInset` 挂顶栏，保 inspector/面板可拖）；右边栏倾向用 NavigationSplitView 第三列（原生可拖+最小宽）承载，下边栏用可拖分隔的底部容器（最小高）。具体实现 design 阶段定。
- **D2 摘要浮层**：`:≡` 触发的 popover/overlay 浮层，内容自适应（非整列）；P0 数据全来自 app-server（`turn/diff/updated` 算行数、`Thread.cwd`、`turn/plan/updated`、commandExecution items）。
- **D3 面板框架**：右栏/下栏抽象出统一的"可显隐 + 空态 + 可拖 + 最小尺寸"面板容器，本期填占位内容，后续 change 往里塞 Diff/终端等。
- **D4 顶栏图标**：左/下/右面板 + 摘要 + 设置；摘要用已就绪的 Codex panel-right SVG 资产（描边=关、填充=开）。

## Risks

- SwiftUI 浮层 + 多面板可拖与 v1 已踩过的 inspector 拖动坑同源——design/build 阶段需在模拟器逐态自检（含折叠/空态/拖动手势，手势靠用户或 UI 测试确认）。
```

## openspec/changes/ipad-workspace-shell/tasks.md

- Source: openspec/changes/ipad-workspace-shell/tasks.md
- Lines: 1-23
- SHA256: c41a6d4f93e0c54b086826c1f71b30866c0a1da0ca36999eb6b87286cc4e0aef

```md
## 1. 顶栏重排（workspace-layout）
- [ ] 1.1 顶部固定全局工具栏按钮重排：左面板 · 下面板 · 右面板 · 摘要(`:≡`) · 设置（去前进/后退）
- [ ] 1.2 inspector/摘要图标改用 Codex 真实 panel-right SVG（描边=关 / 填充=开）

## 2. 摘要悬浮浮层（workspace-layout / session-management）
- [ ] 2.1 摘要从占列 inspector 改为 `:≡` 触发的悬浮浮层（内容自适应，非整列）
- [ ] 2.2 摘要 P0 内容：diff 行数统计（turn/diff/updated 端侧算行）/ cwd / 进度(turn/plan/updated) / 任务(commandExecution 列表)
- [ ] 2.3 空态（无内容时浮层占位）

## 3. 右边栏占位（workspace-layout）
- [ ] 3.1 右边栏整列容器：toggle 显隐（右面板按钮）+ 空态占位
- [ ] 3.2 右边栏可拖改宽 + 最小宽度

## 4. 下边栏占位（workspace-layout）
- [ ] 4.1 下边栏底部容器：toggle 显隐（下面板按钮）+ 空态占位
- [ ] 4.2 下边栏可拖改高 + 最小高度

## 5. 面板框架抽象
- [ ] 5.1 抽象统一的"可显隐 + 空态 + 可拖 + 最小尺寸"面板容器，供右栏/下栏复用，后续 change 往里填内容

## 6. 验收
- [ ] 6.1 模拟器自检：顶栏 5 按钮各自 toggle 对应面板显隐；摘要浮层显 P0 内容；右栏/下栏 空态+可拖+最小尺寸（拖动手势靠 UI 测试或用户确认）
- [ ] 6.2 真机验收（follow-up，沿用 v1 延期约定）
```

## openspec/changes/ipad-workspace-shell/specs/session-management/spec.md

- Source: openspec/changes/ipad-workspace-shell/specs/session-management/spec.md
- Lines: 1-19
- SHA256: a9742f39ae094782d4ee03a58efc5dbf17fa7c572f9825b839fc55308241a87b

```md
## MODIFIED Requirements

### Requirement: 主界面布局可隐藏 inspector 且设置常显
连接就绪后的主界面 SHALL 将「环境信息/摘要」以**悬浮浮层**呈现（由顶部工具栏摘要按钮 `:≡` 切换），而非占整列的 inspector；整体布局遵循 `workspace-layout` 能力（五窗口 + 顶部固定工具栏）。全局设置入口 SHALL 在主界面始终可见。

> 变更说明：v1 曾把环境信息做成可隐藏的占列 inspector（顶栏切换）。本 change 改为：环境信息归入「摘要」悬浮浮层，inspector 占列让位给 `workspace-layout` 的右边栏（承载 Diff/文件/终端等，后续 change 填充）。布局/面板显隐规则统一由 `workspace-layout` 定义。

#### Scenario: 进入主界面默认聚焦侧栏
- **WHEN** 连接进入 ready 状态进入主界面且未选中任何对话
- **THEN** 默认聚焦左侧栏（项目/对话），摘要浮层与右/下栏默认隐藏
- **AND** 中栏不显示大占位卡

#### Scenario: 切换摘要浮层显隐
- **WHEN** 用户点击顶栏摘要按钮（`:≡`）
- **THEN** 摘要悬浮浮层在显示与隐藏之间切换（内容自适应，非整列）

#### Scenario: 主界面保留全局设置入口
- **WHEN** 连接就绪进入主界面（任何面板显隐组合）
- **THEN** 全局设置入口始终可见可用
```

## openspec/changes/ipad-workspace-shell/specs/workspace-layout/spec.md

- Source: openspec/changes/ipad-workspace-shell/specs/workspace-layout/spec.md
- Lines: 1-60
- SHA256: 5b26f21102478dd47b94dbfbf1e2792640528939bc71fd64eccabb5667fff059

```md
## ADDED Requirements

### Requirement: 五窗口工作区布局与层级
iPad 客户端 SHALL 提供复刻 Codex desktop 的五窗口工作区：左边栏（项目/对话）· 中间（对话）· 右边栏（整列）· 下边栏 · 摘要（悬浮浮层）。布局层级：左边栏满高、不被下边栏压短；下边栏只在「中间 + 右边栏」下方铺开并纵向压短它们，不伸到左边栏底下。

#### Scenario: 下边栏不压左边栏
- **WHEN** 下边栏处于打开状态
- **THEN** 左边栏保持满高、不被压短
- **AND** 下边栏横跨「中间 + 右边栏」区域并将其纵向压短

#### Scenario: 横屏五窗口同时可见
- **WHEN** 横屏且右边栏、下边栏均打开
- **THEN** 左边栏 · 中间 · 右边栏 · 下边栏 同屏，按上述层级排布

### Requirement: 顶部固定全局工具栏
iPad 客户端 SHALL 在主界面顶部提供固定全局工具栏，承载面板开关与设置；该工具栏不随任何面板折叠而消失。按钮从左到右：左面板 · 下面板 · 右面板 · 摘要 · 设置（不含前进/后退）。

#### Scenario: 工具栏按钮切换对应面板
- **WHEN** 用户点击「左面板 / 下面板 / 右面板 / 摘要」按钮
- **THEN** 对应面板（左边栏 / 下边栏 / 右边栏 / 摘要浮层）在显示与隐藏之间切换

#### Scenario: 设置入口常显
- **WHEN** 处于主界面（任何面板显隐组合）
- **THEN** 顶栏「设置」入口始终可见可用

### Requirement: 摘要悬浮浮层
iPad 客户端 SHALL 以悬浮浮层（非整列）形式展示「摘要」，由顶栏摘要按钮（`:≡`）切换；内容自适应大小（有多少显多少）。摘要 P0 内容：变更 diff 行数统计、工作目录 cwd、进度（plan）、任务（命令列表）。

#### Scenario: 摘要浮层显示 P0 内容
- **WHEN** 用户打开摘要且当前会话有相应数据
- **THEN** 浮层显示 diff 行数统计（来自 `turn/diff/updated`）、cwd（`Thread.cwd`）、进度（`turn/plan/updated` 的 plan 步骤及状态）、任务（会话内 commandExecution 命令列表）
- **AND** 浮层大小随内容自适应，不占整列

#### Scenario: 摘要空态
- **WHEN** 打开摘要但无可显示数据
- **THEN** 浮层显示空态占位，不报错

### Requirement: 右边栏可显隐整列面板
iPad 客户端 SHALL 提供右边栏整列面板，支持显隐切换、可拖拽改宽、最小宽度；本期内容为占位空态（真实内容由后续 change 提供）。

#### Scenario: 右边栏显隐与拖动
- **WHEN** 用户切换右面板按钮
- **THEN** 右边栏整列在显示与隐藏间切换
- **AND** 显示时可拖拽改宽，且不小于最小宽度

#### Scenario: 右边栏空态占位
- **WHEN** 右边栏打开且本期无真实内容
- **THEN** 显示空态占位

### Requirement: 下边栏可显隐底部面板
iPad 客户端 SHALL 提供下边栏底部面板，支持显隐切换、可拖拽改高、最小高度；本期内容为占位空态（终端等真实内容由后续 change 提供）。

#### Scenario: 下边栏显隐与拖动
- **WHEN** 用户切换下面板按钮
- **THEN** 下边栏在显示与隐藏间切换
- **AND** 显示时可拖拽改高，且不小于最小高度

#### Scenario: 下边栏空态占位
- **WHEN** 下边栏打开且本期无真实内容
- **THEN** 显示空态占位
```

