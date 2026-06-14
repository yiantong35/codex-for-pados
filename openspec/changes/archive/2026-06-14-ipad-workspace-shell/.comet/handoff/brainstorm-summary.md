# Brainstorm Summary

- Change: ipad-workspace-shell
- Date: 2026-06-13

## 确认的技术方案

5 窗口工作区骨架（左/中已有 + 右栏整列占位 + 下栏占位 + 摘要悬浮浮层）。**布局层级（关键）**：左边栏满高、不被下栏压；detail 区（左栏右侧）= VStack：上半 = 中间对话 + 右栏；下半 = 下边栏，横跨中间+右栏、压短它们；左边栏不受影响。

- **顶栏**：`.safeAreaInset(edge:.top)` 挂固定全局工具栏（不用 VStack 包整个 split，避免破坏 inspector 拖动）。按钮左→右：左面板 / 下面板 / 右面板 / 摘要(`:≡`) / 设置（去前进后退）。Codex 真实 panel-right SVG 等图标。
- **摘要**：`.popover(isPresented:)` 锚定 `:≡` 按钮，内容自适应（悬浮气泡）。P0：diff 行数（`turn/diff/updated` 端侧数 +/-）、cwd（`Thread.cwd`）、进度（`turn/plan/updated`→TurnPlanStep）、任务（commandExecution items）。空态占位。
- **右栏**：`.inspector(isPresented:)`——可显隐 + 原生可拖 + 最小宽；配 safeAreaInset 顶栏（v1 证可拖）。本期空态占位。
- **下栏**：detail 区内 VStack 分割 + 可拖 Divider + 最小高；横跨中间+右栏，不伸到左边栏下。本期空态占位。
- **面板框架**：共享"空态视图 + 最小尺寸常量 + toggle 状态"约定（右栏=inspector、下栏=VStack 结构不同，不强求单一容器）。

## 关键取舍与风险

- 规避 v1 已踩坑：顶栏用 safeAreaInset（非 VStack 包 split，保 inspector 拖动）；不叠加系统 sidebarToggle（folded 消失/重复）。
- 下栏选 VStack 分割（控制力强、只压中间+右栏），未选 safeAreaInset.bottom（更适合固定高）/ bottom sheet（模态盖住）。
- 拖动手势 CLI 截图验不了——靠 UI 测试或用户确认（v1 教训）。

## 测试策略

- 单测：diff 行数计算、plan 归约、摘要 P0 派生逻辑、面板 toggle/最小尺寸常量。
- 模拟器逐态自检截图（顶栏 5 按钮、摘要浮层、右/下栏空态）。
- 拖动手势：UI 测试或用户确认。真机 follow-up（沿用 v1 延期）。

## Spec Patch

无需对已有 delta 大改。本 change 新增 `workspace-layout` delta（5 窗口骨架/顶栏/面板框架/摘要浮层场景），并改 `session-management`（inspector 占列 → 摘要浮层 + 顶栏重排）。
