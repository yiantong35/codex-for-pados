# Comet Design Handoff

- Change: workspace-ui-review-fixes-2
- Phase: design
- Mode: compact
- Context hash: e458f7283950acbd30260708d3d27c46a2d2bd8d49674e260024ddebcab5ed2c

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/workspace-ui-review-fixes-2/proposal.md

- Source: openspec/changes/workspace-ui-review-fixes-2/proposal.md
- Lines: 1-47
- SHA256: e47e630c0cb09629169c102d7d6c5e59fdfa9b36aa3fb88ccbe9e0d4c266ccae

```md
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

非破坏性变更：均为既有 iOS SwiftUI 视图层 + Store 层行为修正/补全，不改协议、不改数据模型结构。

## Capabilities

### New Capabilities

<!-- 无新增能力；全部为既有能力的需求级修正/补全 -->

（无）

### Modified Capabilities

- `ipad-review-panel`: 全量 diff 数据源须随工作区（cwd/thread）失效重取，不得跨工作区复用旧缓存（#2）；diff 查看器须提供行号、长行横向滚动、可选文本、适度字号（#8-diff）。
- `ipad-right-panel-tabs`: 窄窗列可见性计划须在中间档（center+right 可容纳）与用户显式请求右栏时据实展开右栏，不得静默失效（#3）。
- `ipad-review-actions`: 摘要浮层/进度卡须能跳转到右栏审查面板（#4）；发起审查须给出可见反馈（#9）。
- `ipad-localization`: 面向用户的字符串须为正确本地化文案并跟随注入 locale，不得发布占位假串或散落硬编码中文（#5）。
- `ipad-touch-accessibility`: 开关类控件须有可被 VoiceOver 关联的语义标签，点按控件须暴露 button trait（#6）。
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
```

## openspec/changes/workspace-ui-review-fixes-2/design.md

- Source: openspec/changes/workspace-ui-review-fixes-2/design.md
- Lines: 1-44
- SHA256: ac6dc5606b2e5005ea9bce5d39717ade95ab826ef28c2f76ed3d83acdae2b3d5

```md
## Context

首轮 `workspace-ui-review-fixes` 已交付并归档，其 UI 代码在 release 线 `e5144549` 引入、当前基线为 `ee22d660`（PR #50 合入后，未触碰本 change 相关 UI 面）。第二轮外部 review 逐条经本地读码核实的 10 处缺口，本质分三类：

1. **落码未接入生产 / 未接线**（#4 导航回调恒 nil、#10 阈值仅测试调用）；
2. **跨工作区共享状态污染**（#2 全量 diff 按 mode 缓存不随 cwd 失效）；
3. **质量洞**（#3 窄窗计划逻辑漏档、#5 i18n、#6 a11y、#7 tab 滚动、#8 可读性、#9 可见反馈）。

本 change 是纯 iOS SwiftUI 视图层 + Store 层修正，不触协议 / 数据模型 / 安全面。本文件给高层方向决策；逐行实现方案在 `/comet-design`（brainstorming）阶段细化。

## Goals / Non-Goals

**Goals:**

- 10 处发现全部闭合，且每处以「可验证的接入生产行为」为准（非孤立函数单测通过即算），避免重蹈首轮「函数测过但生产未接线」的过度声称。
- 纯逻辑部分（缓存失效键、列可见性档位、近底阈值、本地化键存在性）以 XCTest 锁定；接线/观感部分以模拟器+真机验收锁定。
- 守恒定原则：`ui-adaptation-baseline`（横竖屏+手势+软/硬键盘）、`energy-awareness`（事件驱动、无新增轮询/定时器）。

**Non-Goals:**

- 不碰 security / relay / E2E / transport / Keychain。
- 不重构审查/ diff 数据模型（`DiffFile`/`DiffLine`/`ReviewDiffSource` 结构不变）。
- 不推翻 #9 的 D4 fire-and-forget 设计（不加形同虚设的 `isStarting` 假防抖）——只补可见反馈。
- 不处理 release 线上残留的已归档 `workspace-ui-review-fixes/tasks.md`（可选清理项，另计）。

## Decisions

- **D1（#2 缓存失效）**：`ReviewTabView` 的全量 diff 缓存键从 `mode` 扩为 `mode + cwd`（cwd 取自选中 thread，已能代表工作区/线程身份）。`.task(id:)` 绑复合键，cwd 变即重取；`fullDiff` 随之置空。纯状态推导，可单测。
- **D2（#3 窄窗档位）**：`columnVisibilityPlan` 引入「最后请求侧」概念——当 `wantRight` 为真或总宽落在 center+right 可容纳档（≥ 某阈值且 < 668）时，据实展开右栏，而非 `wantLeft` 一票否决。判定为纯函数，穷举档位单测。
- **D3（#4 导航接线）**：在 `RootSplitView` 把「打开右栏审查 tab」的闭包注入 `SummaryPopoverView(onOpenReview:)`，复用已存在的右栏 tab 选择状态（与 review-actions 能力现有跳转信号同源）。不新增全局状态。
- **D4（#5 i18n）**：`conv.item.unknown` 换正确本地化文案（en/zh 各自正确）；`ConnectionStore`/`FileBrowserStore` 硬编码中文改走 `String(localized:)` 并确保跟随注入 locale（与首轮 D5 注入 locale 同范式）。补一条「xcstrings 无占位假串」的守卫测试。
- **D5（#6 a11y）**：空 `Toggle` 标签补 `accessibilityLabel(skill 名)`；`onTapGesture` 类改造为 `Button` 或补 `.accessibilityAddTraits(.isButton)`（沿用首轮 D7 触控范式）。
- **D6（#7 tab 滚动）**：`TabBarView` 外套 `ScrollViewReader`，活动 tab `.id(...)`，在选中变化时 `withAnimation { proxy.scrollTo(activeId, anchor: .center) }`。事件驱动，无定时器。
- **D7（#8 可读性）**：四项——(a) diff/文件行左侧行号 gutter；(b) 长行改横向 `ScrollView(.horizontal)` 不折行；(c) `.textSelection(.enabled)`；(d) 字号 caption2→body/caption 适度上调 + 行高。均为视图修饰，保持横竖屏自适应。
- **D8（#9 可见反馈）**：发起审查后给短时可见态（如按钮态切换/toast/inline「审查已发起」），基于既有事件（回调返回）驱动，不引入轮询、不改 fire-and-forget。
- **D9（#10 阈值接入）**：把生产近底判定接上 `ScrollAnchorPolicy.isNearBottom(threshold:120)`——最简事件驱动做法为把 sentinel 视图从 1pt 高改为 120pt 近底带（onAppear 即代表「进入近底 120pt」），或以底部锚的可见性等价映射到该策略函数；保持无几何轮询。具体取法在 design 阶段定，但必须让生产真正调用该策略函数（消灭死代码）。

## Risks / Trade-offs

- **R1（#10 语义偏移）**：把 sentinel 从 1pt 改 120pt 会让「近底」判定更宽松，可能改变既有自动滚手感。缓解：以策略函数为单一真源 + 单测锁定阈值；真机验收横竖屏各验一遍自动滚/新消息浮标。
- **R2（#8 横滚与横竖屏自适应冲突）**：长行横滚叠加 `ReviewPanelView` 既有宽度自适应（520 阈值横竖布局）可能嵌套滚动。缓解：横滚只包 diff 文本区，外层纵向滚动/布局不变；真机验证嵌套滚动手感。
- **R3（#3 档位回归）**：改列可见性逻辑可能回归首轮 D3/D4（P1#2「右栏三 tab 全部可见」）。缓解：穷举 320/494/668/更宽档位单测，覆盖首轮既有场景不破。
- **R4（#4 状态串台）**：接线摘要→审查跳转若误用共享状态，可能重演首轮 D1 侧聊/主对话状态串台。缓解：复用只读跳转信号，不写共享 ActiveConversationHolder。
- **R5（过度声称复发）**：首轮教训——孤立函数测过≠生产接入。缓解：每条验收以「生产路径可见行为」为准，接线项必须真机/模拟器眼见。
```

## openspec/changes/workspace-ui-review-fixes-2/tasks.md

- Source: openspec/changes/workspace-ui-review-fixes-2/tasks.md
- Lines: 1-30
- SHA256: 07f88ddae817a0fa4ca2c06df17711fa9c28ed61966cce8fd5213bf75592e54c

```md
# Tasks — workspace-ui-review-fixes-2

> 基线 `ee22d660`。每条以「生产路径可见行为」为验收准绳（首轮教训：孤立函数测过≠生产接入）。
> 守 `ui-adaptation-baseline`（横竖屏+手势+软/硬键盘）与 `energy-awareness`（事件驱动、无新增轮询/定时器）。

## 1. P1 清晰缺陷（correctness / release-blocking）

- [ ] 1.1 #2 `ReviewTabView` 全量 diff 缓存按 `cwd`(+thread) 失效：`.task(id:)` 绑 `mode+cwd` 复合键，cwd 变化即清空 `fullDiff` 重取；补单测覆盖「切 thread 后不复用旧工作区 diff」。
- [ ] 1.2 #3 `WorkspaceMetrics.columnVisibilityPlan` 窄窗档位修正：`wantRight` 为真或总宽落在 center+right 可容纳档时据实展开右栏，不再 `wantLeft` 一票 `showRight:false`；穷举 320/494/668/宽档单测，含首轮 D3/D4 既有场景不回归。
- [ ] 1.3 #5 消除占位假串与硬编码中文：`conv.item.unknown` en/zh 换正确本地化文案；`ConnectionStore:432`、`FileBrowserStore:103` 等改 `String(localized:)` 跟随注入 locale；补「xcstrings 无占位假串（无『帮紧你』等）」守卫测试。

## 2. P2 接线 / 完成（wiring & completion）

- [ ] 2.1 #4 接线摘要→审查跳转：`RootSplitView` 向 `SummaryPopoverView` 注入 `onOpenReview`（复用右栏 tab 选择只读信号，不写共享 ActiveConversationHolder）；chevron 不再恒 `.disabled`，点击切到右栏审查 tab；删「后续接」注释。
- [ ] 2.2 #6 a11y 补全：`SkillsGroupContent` 空 `Toggle` 补 `accessibilityLabel(skill 名)`；同类空标签开关一并补；点按控件（onTapGesture 类）补 button trait；VoiceOver 朗读校验。
- [ ] 2.3 #7 `TabBarView` 活动 tab 自动滚入可见：外套 `ScrollViewReader`，活动 tab `.id`，选中变化 `scrollTo(anchor:.center)`（事件驱动无定时器）。

## 3. P2–P3 可读性 / 反馈 / 死代码接入

- [ ] 3.1 #8 diff 查看器可读性（`ReviewPanelView`）：行号 gutter + 长行横向滚动（不折行）+ `textSelection(.enabled)` + 字号/行高调优；横滚只包 diff 文本区，不破 520 横竖自适应。
- [ ] 3.2 #8 文件查看器可读性（`FileBrowserView.contentArea`）：同上四项（行号/横滚/可选/字号行高）。
- [ ] 3.3 #9 审查发起可见反馈：`ReviewTabView` 发起后给短时可见态（按钮态/inline/toast），基于回调返回事件驱动；不加假防抖、不改 D4 fire-and-forget。
- [ ] 3.4 #10 近底阈值接入生产：让生产近底判定真正调用 `ScrollAnchorPolicy.isNearBottom(threshold:120)`（sentinel 1pt→120pt 近底带 或等价映射），消灭死代码；保持事件驱动；单测锁定阈值，真机验横竖屏自动滚/新消息浮标手感。

## 4. 验收与恒定原则守卫

- [ ] 4.1 全量 iOS 测试绿（新增单测 + 既有回归）；xcstrings 守卫测试通过。
- [ ] 4.2 `ui-adaptation-baseline`：#3/#4/#7/#8/#9/#10 涉 UI 项，横竖屏各验一遍；软键盘/外接键盘不遮挡、可交互。
- [ ] 4.3 `energy-awareness`：确认无新增轮询/定时器（#7/#9/#10 均事件驱动）。
- [ ] 4.4 安全面零触碰核对：grep 确认未改 relay/E2E/transport/Keychain/security 符号。
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-conversation-ux/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-conversation-ux/spec.md
- Lines: 1-16
- SHA256: bc85aaed3a69a82b5aae222005581df9f9a76a0a89c3b6ea3a5b7f4787ea0ed1

```md
## ADDED Requirements

### Requirement: 近底判定采用 120pt 阈值策略函数
对话自动滚到底的「近底」判定 SHALL 由生产路径真正调用 `ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:)`（阈值 120pt）产出，不得让该策略函数仅存在于测试而生产用等价 1pt sentinel 旁路（消灭死代码）。判定 SHALL 事件驱动（随滚动/布局几何变化），不得引入几何轮询或周期定时器。

#### Scenario: 生产近底判定调用策略函数
- **WHEN** 对话滚动位置变化，需判定是否近底
- **THEN** 生产路径以实测底部距离调用 `isNearBottom(distanceToBottom:threshold:120)`，据其结果决定自动滚/浮标

#### Scenario: 阈值边界
- **WHEN** 底部距离为 120pt（含）以内
- **THEN** 判定为近底；超过 120pt 判定为非近底

#### Scenario: 近底判定不引入周期唤醒
- **WHEN** 近底判定随滚动/布局变化更新
- **THEN** 仅由几何/布局变化事件驱动，无几何轮询或周期定时器
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-file-browser/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-file-browser/spec.md
- Lines: 1-12
- SHA256: 1c60ff820f1d093a26275c7932447dc776176331febfb2b66f06547adc79ae21

```md
## ADDED Requirements

### Requirement: 文件查看器可读性
文件内容查看器 SHALL 提供：行号 gutter、长行横向滚动（不折行）、`textSelection` 可选可复制、适度上调的字号/行高。横向滚动 SHALL 只包裹文件正文区，不破坏 520 宽度阈值的横竖自适应布局与外层纵向滚动。

#### Scenario: 长行横向滚动不折行
- **WHEN** 文件某行文本超过可视宽度
- **THEN** 该行不软换行，可在正文区内横向滚动查看，外层纵向布局与横竖自适应不变

#### Scenario: 行号与可选文本
- **WHEN** 查看文本文件内容
- **THEN** 每行左侧显示 1-based 行号，文件文本可被选中复制
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-localization/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-localization/spec.md
- Lines: 1-16
- SHA256: 9c8d28109e743a1e7592374a2c2fdf7302f1d826b83b78ef692f88e810c5bc11

```md
## ADDED Requirements

### Requirement: 无占位假串且 Store 文案跟随注入 locale
面向用户的字符串 SHALL 为正确本地化文案，不得发布占位假串（如「帮紧你，帮紧你」）。Store 层面向用户的展示文案（连接失败/超时/信任撤销、目录加载失败等）SHALL 跟随应用内注入的 locale（经 `L10n.string(key, locale:)` 读取与注入同源的 locale），不得硬编码单一语言。开发者日志字符串不在此约束内。

#### Scenario: 无占位假串
- **WHEN** 校验本地化资源（xcstrings）与 Store 展示文案
- **THEN** 不存在占位玩笑串（如「帮紧你」），`conv.item.unknown` 为正确 en/zh 文案

#### Scenario: 切换英文后 Store 文案无残留中文
- **WHEN** 应用内注入 locale 切换为英文，触发连接失败/目录加载失败等展示文案
- **THEN** 展示为英文文案，无残留硬编码中文

#### Scenario: 展示契约不变
- **WHEN** 本地化 Store 展示文案
- **THEN** `.failed(String)` 等展示数据契约保持不变，仅文案随 locale 变化
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-multi-connection/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-multi-connection/spec.md
- Lines: 1-12
- SHA256: 3497d2d95cb1f84d145f80d8133657cbe8afad7354c554cc511f5223c7ccc322

```md
## ADDED Requirements

### Requirement: 活动机器 tab 自动滚入可见区
机器 tab 栏 SHALL 在活动 session 变化时把活动 tab 自动滚入可见区（居中），使活动 tab 不停留在离屏位置。滚动 SHALL 事件驱动（随活动 session 变化触发），不得引入轮询或周期定时器。

#### Scenario: 切换到离屏 tab 自动滚入
- **WHEN** 活动 session 切换到当前不在可视范围的机器 tab
- **THEN** tab 栏自动滚动使该活动 tab 居中可见

#### Scenario: 自动滚动事件驱动
- **WHEN** 活动 tab 自动滚入
- **THEN** 仅由活动 session 变化事件触发，无轮询或周期定时器
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-review-actions/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-review-actions/spec.md
- Lines: 1-23
- SHA256: 0d600fbfdb690d6b2be57700600427e7cf8613e0c3cd357b40f2b7705183de70

```md
## ADDED Requirements

### Requirement: 摘要浮层可跳转到右栏审查面板
摘要浮层的「变更」入口 SHALL 能跳转到右栏审查面板：注入的跳转信号 SHALL 复用既有右栏 tab 选择意图（打开右栏并选中审查 tab），不得写入会话共享状态导致侧聊/主对话串台。跳转 chevron SHALL 在信号可用时可点击，不再恒 disabled。

#### Scenario: 点击摘要变更入口打开审查面板
- **WHEN** 用户在摘要浮层点击「变更」行的跳转 chevron
- **THEN** 右栏打开并选中审查 tab，展示当前工作区变更；不修改会话共享状态

#### Scenario: 跳转 chevron 可用
- **WHEN** 摘要浮层在具备跳转信号的上下文中呈现
- **THEN** 跳转 chevron 可点击（非 disabled）

### Requirement: 发起审查给出可见反馈
在审查面板发起 AI 审查后 SHALL 给出短时可见反馈（发起态提示），基于发起调用的返回事件驱动。反馈 SHALL 为一次性短时呈现后自动收起，不引入轮询/周期定时器，不改变 fire-and-forget 的发起本质。

#### Scenario: 发起后短时提示
- **WHEN** 用户点击发起本轮/全量审查
- **THEN** 审查面板内短时显示「审查已发起」提示，随后自动收起

#### Scenario: 反馈不引入周期唤醒
- **WHEN** 发起反馈呈现与收起
- **THEN** 仅用一次性延时收起，无轮询或周期定时器
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-review-panel/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-review-panel/spec.md
- Lines: 1-27
- SHA256: d736fe4daaa56173731bb16e234f34fa3f1e47315d670eaeeb82dadd61646532

```md
## ADDED Requirements

### Requirement: 全量 diff 数据源随工作区/线程失效重取
审查面板的全量 diff 缓存 SHALL 以 `mode + cwd` 复合键失效：当选中 thread（cwd）变化时，SHALL 丢弃旧工作区的全量 diff 并按新 cwd 重新拉取，不得跨工作区复用旧缓存。cwd 为空时 SHALL 不发起请求且不崩溃。

#### Scenario: 切换 thread 后不复用旧工作区 diff
- **WHEN** 已加载工作区 A 的全量 diff，随后切换到工作区 B（cwd 变化）
- **THEN** 丢弃 A 的全量 diff，按 B 的 cwd 重新拉取并展示 B 的 diff

#### Scenario: 同 cwd 不重复请求
- **WHEN** 全量 diff 已按当前 cwd 加载，视图在同一 cwd 内重建
- **THEN** 不重复发起全量 diff 请求

#### Scenario: 无选中 thread 时不请求
- **WHEN** 无选中 thread（cwd 为空）
- **THEN** 不发起全量 diff 请求，界面不崩溃

### Requirement: diff 查看器可读性
审查面板的逐行 diff SHALL 提供：行号 gutter、长行横向滚动（不折行）、`textSelection` 可选可复制、适度上调的字号/行高。横向滚动 SHALL 只包裹 diff 正文区，不破坏面板 520 宽度阈值的横竖自适应布局与外层纵向滚动。

#### Scenario: 长行横向滚动不折行
- **WHEN** diff 某行文本超过可视宽度
- **THEN** 该行不软换行，可在 diff 正文区内横向滚动查看，外层纵向布局与横竖自适应不变

#### Scenario: 行号与可选文本
- **WHEN** 查看某文件逐行 diff
- **THEN** 每行左侧显示行号，diff 文本可被选中复制
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-right-panel-tabs/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-right-panel-tabs/spec.md
- Lines: 1-16
- SHA256: a912393f6c9e42f372a2056266831989863883b5885df7f68430be974ee2b741

```md
## ADDED Requirements

### Requirement: 分屏中间档右栏据实展开（消除死按钮）
自绘三栏窄窗降级 SHALL 记录「最后请求侧」：当 app 窗口宽度落在 center+right 可容纳档（≥494pt 且 <668pt）、且用户同时想要左右栏时，SHALL 按最后请求侧展开对应单侧，不得无条件保左丢右导致右栏入口静默失效。全屏宽度（≥668pt）SHALL 三栏均按用户意图展示。

#### Scenario: 中间档最后点右则展开右栏
- **WHEN** app 窗口宽度在 [494,668)、左右栏都被想要、且用户最后请求的是右栏
- **THEN** 展开右栏（收起左栏），右栏入口生效而非静默失效

#### Scenario: 中间档最后点左则展开左栏
- **WHEN** app 窗口宽度在 [494,668)、左右栏都被想要、且用户最后请求的是左栏
- **THEN** 展开左栏（收起右栏）

#### Scenario: 全屏宽度三栏齐全
- **WHEN** app 窗口宽度 ≥668pt（如 iPad Pro 11" 全屏竖 834 / 横 1194）
- **THEN** 左中右三栏均按用户意图展示，不触发窄窗降级
```

## openspec/changes/workspace-ui-review-fixes-2/specs/ipad-touch-accessibility/spec.md

- Source: openspec/changes/workspace-ui-review-fixes-2/specs/ipad-touch-accessibility/spec.md
- Lines: 1-12
- SHA256: a295b2e5733d5a27d280a46ba0f7b8e4d316c7a2c05375c36e3e0330f859fb7c

```md
## ADDED Requirements

### Requirement: 开关控件语义标签与点按控件 button trait
空可见标签的开关控件（如 `Toggle("").labelsHidden()`）SHALL 提供可被 VoiceOver 关联的 `accessibilityLabel`（如对应 skill 名）。以 `onTapGesture` 实现的点按控件 SHALL 暴露 button trait（`.accessibilityAddTraits(.isButton)` 或改用 `Button`），使辅助技术识别其可点按语义。

#### Scenario: 空标签开关具备语义标签
- **WHEN** VoiceOver 聚焦 SkillsGroupContent 中空标签的 skill 开关
- **THEN** 朗读出对应 skill 名，可关联开关与其含义

#### Scenario: 点按控件暴露 button trait
- **WHEN** VoiceOver 聚焦以手势实现的点按控件
- **THEN** 该控件被识别为按钮（具备 button trait）
```

