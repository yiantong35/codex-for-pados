## Why

首轮 `workspace-ui-review-fixes`（已归档 2026-08-05，PR #48 之后并入 release 线 `e5144549`，现基线 `ee22d660`）交付后，第二轮外部 UI review 发现**上一轮修复留下了 10 处未闭合缺口**：部分修复只落在代码路径但未接入生产（死代码 / 未接线导航）、跨工作区共享状态污染、以及 i18n / a11y / 可读性 / 可见反馈的洞。这些缺口逐条经本地按基线 `ee22d660` 直接读码核实为真，需在一个后继 change 内一次性收口。

## What Changes

- **#2 审查全量 diff 跨工作区/线程缓存污染**：`ReviewTabView.fullDiff` 仅按 `mode` 缓存（`.task(id: mode)` + `fullDiff == nil` 守卫），切换 thread（cwd 变化）后仍显示旧工作区 diff，不刷新。改为按 `cwd`（+thread）失效并重取。
- **#3 窄窗右栏「死按钮」**：`WorkspaceMetrics.columnVisibilityPlan` 在 `wantLeft` 为真时无条件 `showRight:false`，导致 494–667pt 中间档（center+right 本可容纳）下、以及用户刚点「打开右栏」后，右栏入口静默无效。改为记录最后请求侧、在可容纳档位据实展开。
- **#4 SummaryPopover / 进度卡 →审查面板跳转未接线**：`RootSplitView` 构造 `SummaryPopoverView` 时未传 `onOpenReview`，回调恒 `nil` → chevron 按钮 `.disabled`，代码留「后续接」注释。接线该导航信号，使摘要浮层可跳转到右栏审查 tab。
- **#5 占位假串与散落硬编码中文**：`conv.item.unknown` 的 en 与 zh 两条 value 均为占位玩笑串「帮紧你，帮紧你」随生产发布（release-blocking）；另有 `ConnectionStore:432`、`FileBrowserStore:103` 等硬编码中文不跟随注入 locale。改为正确本地化串并跟随注入 locale。
- **#6 a11y 空标签与缺失 button trait**：`SkillsGroupContent` 的 `Toggle("", …).labelsHidden()` 使 VoiceOver 无法把开关关联到 skill 名；同类空标签控件补 `accessibilityLabel`，点按控件补 button trait。
- **#7 机器 Tab 无自动滚动**：`TabBarView` 用纯 `ScrollView(.horizontal)` 无 `ScrollViewReader`/`scrollTo`，活动 tab 可停在离屏位置。接入 `ScrollViewReader`，切换时把活动 tab 滚入可见区。
- **#8 diff / 文件查看器可读性**：`ReviewPanelView.diffLineRow` 与 `FileBrowserView.contentArea` 已用 monospace + 红绿 + `+/-`，但缺行号、长行折行（非横滚）、文本不可选。补：**行号栏、长行横向滚动、`textSelection(.enabled)`、字号/行高调优**（用户四项全选）。
- **#9 审查发起无可见反馈**：`ReviewTabView` 的 startReview 为 fire-and-forget（设计 D4，`await` 微秒即返回，故不设「假防抖」），但用户点按后审查面板无任何可见反馈（结果只在主对话回显）。补**可见反馈**（不改 D4 fire-and-forget 本质、不加形同虚设的防抖态）。
- **#10 近底阈值死代码未接入生产**：`ScrollAnchorPolicy.isNearBottom(threshold:120)` 仅被单测调用；生产用 1pt sentinel（`Color.clear.frame(height:1)` 的 onAppear/onDisappear）判定近底。把 120pt 阈值接入生产判定，保持事件驱动（不引入轮询/几何定时器）。
- **恢复后的全面收口**：修正进度卡伪按钮语义并把变更文件入口强类型路由到 Review；隔离 Side Chat；为 AI Review 增加重复提交门闩与失败反馈；补齐动态 locale、全局 44pt 命中区、非颜色状态表达与 Reduce Motion；在 `<494pt` 用右栏覆盖层消除不可达区。

非破坏性变更：均为既有 iOS SwiftUI 视图层 + Store 层行为修正/补全，不改协议、不改数据模型结构。

## Capabilities

### New Capabilities

<!-- 无新增能力；全部为既有能力的需求级修正/补全 -->

（无）

### Modified Capabilities

- `ipad-review-panel`: 全量 diff 数据源须随工作区（cwd/thread）失效重取，不得跨工作区复用旧缓存（#2）；diff 查看器须提供行号、长行横向滚动、可选文本、适度字号（#8-diff）。
- `ipad-right-panel-tabs`: 窄窗列可见性计划须在中间档据实展开；物理宽度不足时以覆盖层保持右栏可达，首次点击即可聚焦（#3）。
- `ipad-review-actions`: 摘要浮层/进度卡须能跳转到右栏审查面板且不污染 Side Chat；发起审查须防重复并给出成功/失败反馈（#4/#9）。
- `ipad-localization`: 面向用户的字符串须为正确本地化文案并跟随注入 locale，不得发布占位假串或散落硬编码中文（#5）。
- `ipad-touch-accessibility`: 开关与点按控件具备正确语义；主要图标控件达到 44pt；状态不只依赖颜色并尊重 Reduce Motion（#6）。
- `ipad-multi-connection`: 机器 Tab 栏须在切换时把活动 tab 自动滚入可见区（#7）。
- `ipad-file-browser`: 文件内容查看器须提供行号、长行横向滚动、可选文本、适度字号（#8-file）。
- `ipad-conversation-ux`: 对话自动滚到底须依据「近底阈值」判定（生产接入 120pt 阈值），保持事件驱动（#10）。

## Impact

- **代码**（iOS，`ios/CodexRemote/`）：
  - Views/Workspace：`ReviewTabView.swift`（#2/#9）、`WorkspaceMetrics.swift`（#3）、`ReviewPanelView.swift`（#8-diff）、`FileBrowserView.swift`（#8-file）、`RightPanelContainerView.swift` / `SummaryPopoverView.swift`（#4）
  - Views：`RootSplitView.swift`（#4 接线）、`ConversationView.swift`（#10）、`TabBarView.swift`（#7）、`Settings/SkillsGroupContent.swift`（#6）
  - Resources：`Localizable.xcstrings`（#5）；Stores：`ConnectionStore.swift`、`FileBrowserStore.swift`（#5 硬编码中文）
- **测试**：新增/改 XCTest 覆盖纯逻辑（缓存失效键、列可见性档位、近底阈值判定、本地化键存在性）；UI 接线项走真机/模拟器验收。
- **不影响**：security / relay / E2E / transport / Keychain 面（本 change 明确不碰）；无新增轮询/定时器。
- **恒定原则**：守 `ui-adaptation-baseline`（横竖屏 + 手势 + 软/硬键盘）；守 `energy-awareness`（#10 事件驱动、无空转）；#5/#6 属安全无关的用户可见质量项。
- **已知遗留（非本 change 范围，登记）**：release 线上残留一份已归档的 `openspec/changes/workspace-ui-review-fixes/tasks.md`（无 `.comet.yaml`，comet 相位检测已跳过），属可选清理项，不在本 change 处理。
