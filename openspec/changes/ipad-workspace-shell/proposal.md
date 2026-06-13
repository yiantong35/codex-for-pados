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
