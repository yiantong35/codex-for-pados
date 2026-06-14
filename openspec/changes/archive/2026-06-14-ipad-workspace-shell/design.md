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
