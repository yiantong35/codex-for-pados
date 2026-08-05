---
comet_change: workspace-ui-review-fixes-2
role: technical-design
canonical_spec: openspec
---

# workspace-ui-review-fixes-2 — 技术设计

> 承接已归档 `workspace-ui-review-fixes`；基线 release 线 `ee22d660`。
> 第二轮外部 UI review 10 处发现（#2–#10）逐条闭合，每处以「生产路径可见行为」验收（守首轮教训 R5：孤立函数测过≠生产接入）。
> 恒定原则：`ui-adaptation-baseline`（横竖屏 + 手势 + 软/硬键盘）、`energy-awareness`（事件驱动、无新增轮询/定时器）、`security-first`（本 change 不碰 security/relay/E2E/transport/Keychain 逻辑）。
> 需求级验收场景见 OpenSpec delta spec（canonical）。本文件只写「怎么做 + 为何 + 风险 + 测试」。

## 1c 已定决策（用户确认）

| 决策点 | 选择 | 依据 |
|---|---|---|
| #10 阈值接入 | **B：GeometryReader 真调策略函数** | design D9 明确要求真正调用 `isNearBottom(threshold:120)` 消灭死代码 |
| #3 窄窗档位 | **(a) 只修分屏 [494,668) 档；<494pt 超窄档 gap 登记 BACKLOG** | iPad Pro 11" 全屏（竖 834/横 1194 > 668）三栏本就齐全；超窄档右栏不可达属既有 gap，修它=范围蔓延+新全屏机制 |
| #9 反馈形态 | **复用连接横幅 Capsule 样式 inline 提示条** | 全 app 现零 toast；引入全局 toast 应另开 change。Capsule 样式风格统一 |

## D1 / #2 — 全量 diff 跨工作区/线程缓存失效

**现状**：`ReviewTabView` `@State fullDiff: String?`；`.task(id: mode)` 内 `guard mode == .full, fullDiff == nil, let cwd, let fetch…`。缓存键仅 `mode`，切 thread（cwd 变）后 `fullDiff != nil` → 不重取 → 显示旧工作区 diff。

**方案**：`.task(id:)` 绑定复合键 `mode + cwd`（cwd 取自选中 thread，代表工作区/线程身份）。cwd 变即触发 task 重跑；进入时先把 `fullDiff = nil`（或以 `guard` 逻辑保证换 cwd 必重取）。纯状态推导。
**边界**：cwd 为 nil（无选中 thread）时不请求、不崩；同 cwd 再进不应重复拉取（保 `fullDiff == nil` 守卫仅在同键内生效）。
**测试**：单测锁「切 thread 后不复用旧工作区 diff」「同 cwd 不重复请求」。

## D2 / #3 — 分屏中间档右栏死按钮

**现状**：唯一 caller `ResizableColumns.swift:38`，`WorkspaceMetrics.columnVisibilityPlan(total:wantLeft:wantRight:)`。常量实测：`threeColumnMinTotalWidth=668`、`leftPlusCenter=454`、`centerPlusRight=494`。Bug：`if wantLeft, total >= leftPlusCenter { showLeft:true, showRight:false }`（67-69）在 [494,668) 档无条件保左丢右；`centerPlusRight` 分支（71-73）被 `!wantLeft` 门控 → 左右都想要时右栏永远静默失效。

**方案**：`columnVisibilityPlan` 增 `lastRequested: RequestedSide`（`.left/.right/none`）tiebreaker 参数（保持纯函数）。档位逻辑：
- `total >= 668`：尊重 `wantLeft/wantRight` 原样（不变）。
- `494 <= total < 668` 且左右都想要：两单侧组合都物理可容纳但不能同时 → 按 `lastRequested` 展开单侧（`.right` → showRight，其余 → showLeft）。只想要一侧时展开该侧（若该侧组合可容纳）。
- `454 <= total < 494`：仅左+中可容纳 → 有 `wantLeft` 则 showLeft，否则仅中。
- `total < 454`：仅中栏。
`WorkspaceLayoutStore` 记录最近一次被打开的侧栏（`leftVisible`/`showRight` 置真的动作点更新 `lastRequested`）；`ResizableColumns` 把它传入。
**范围界定**：<494pt 超窄档右栏完全不可达（无 overlay/全屏 fallback，`RightPanelContainerView.fullScreenCover` 仅在 `effRightVisible` 时挂载）属**既有 gap**，本轮不修，登记 BACKLOG。
**风险 R3**：改档位逻辑勿回归首轮 D3/D4。注意 `ipad-right-panel-tabs`「320pt 三 tab 均可见」指**右栏自身宽度**下 tab 不裁剪，与本处「app 窗口宽度」正交，不冲突。
**测试**：穷举 320/454/494/667/668/834/1194 × {想左/想右/都想/都不想} × lastRequested 单测；显式覆盖「[494,668) 都想要 + 最后点右 → 右展开」「全屏 834/1194 三栏齐全」。

## D3 / #4 — 摘要浮层→审查面板跳转接线

**现状**：`SummaryPopoverView.onOpenReview` 形参与 `.disabled(onOpenReview == nil)` 已就位；`RootSplitView` 构造时未传 → nil → chevron disabled，留「后续接」注释。
**方案**：`RootSplitView` 注入 `onOpenReview: { layout.requestRightPanel(.review) }`，复用既有 `RightPanelIntent` 意图载体（`WorkspaceLayoutStore.requestRightPanel` 置 `showRight=true` + `pendingRightPanelIntent=.review`）。删「后续接」注释。
**风险 R4**：不写 `ActiveConversationHolder` 等共享状态，只用只读跳转意图，规避首轮 D1 侧聊/主对话串台。
**边界**：全屏（>668）点击右栏 tab 切到审查即生效；分屏 [494,668) 与 #3 tiebreaker 协同（点击=最后请求右侧）；<494pt 受既有 gap 限制（BACKLOG）。
**测试**：接线项走模拟器/真机验收（点 chevron → 右栏审查 tab 打开）。

## D4 / #5 — i18n 占位假串与硬编码中文

**现状**：`conv.item.unknown` en/zh 均为占位假串「帮紧你，帮紧你」；`ConnectionStore`/`FileBrowserStore` 面向用户串硬编码中文，不跟随注入 locale。
**方案**：
- `Localizable.xcstrings`：`conv.item.unknown` en/zh 换正确文案。
- Store 面向用户串走 `L10n.string(key, locale: LocaleManager.currentLocale)`——**不用 `String(localized:)`**（它按系统语言选表、忽略应用内注入 locale）。新增静态 `LocaleManager.currentLocale`（读同一 UserDefaults `app_language`，与 `.environment(\.locale)` 注入同源）。
- **严格区分**：用户可见串（`.failed(...)` 展示文案、`node.error`）localize；开发者日志 `connLog.*` 不碰。`.failed(String)` 枚举契约不变（外科式，不触 relay 逻辑；本地化展示串 ≠「碰 relay」）。
**待本地化清单**（用户可见）：`ConnectionStore` 172/224/238/432/438/454-461、`ConnectionTimeoutError.errorDescription`(9)、`FileBrowserStore:103`。
**测试**：xcstrings 无占位假串守卫测试（grep「帮紧你」等）；切英文后 Store 错误文案无残留中文（注入 locale 单测）。

## D5 / #6 — a11y 空标签与 button trait

**方案**：`SkillsGroupContent` 空 `Toggle("",…).labelsHidden()` 补 `.accessibilityLabel(Text(skill.name))`；同类空标签开关一并补；`onTapGesture` 类点按控件补 `.accessibilityAddTraits(.isButton)`（沿用首轮 D7 触控范式）。
**测试**：VoiceOver 朗读校验（模拟器 Accessibility Inspector）。

## D6 / #7 — 活动机器 tab 自动滚入可见

**现状**：`TabBarView` 纯 `ScrollView(.horizontal)` + `HStack`，无 `ScrollViewReader`/`scrollTo`，活动 tab 可离屏。
**方案**：外套 `ScrollViewReader`，每 tab `.id(machine.id)`，`onChange(of: sessions.activeSessionId) { withAnimation { proxy.scrollTo(id, anchor:.center) } }`。事件驱动、无定时器（守 energy-awareness）。
**测试**：切到离屏 tab 自动滚入中心（模拟器/真机，横竖屏各验）。

## D7 / #8 — diff / 文件查看器可读性（四项）

**现状**：`ReviewPanelView`（threshold=520 横竖自适应）与 `FileBrowserView.contentArea` 正文均 `Text` + `.system(.caption2,.monospaced)` + `maxWidth:.infinity` 无 `lineLimit`（长行软换行）+ 纵向-only ScrollView；无 gutter、无横滚、无 textSelection。selectable 先例 `ItemCards.swift:265`（逐行 split diff）。
**方案（两处一致）**：
- (a) **行号 gutter**：行左侧定宽 monospace 行号列（diff 用文件内行号；文件查看器用 1-based 行号）。
- (b) **长行横向滚动不折行**：正文行外套 `ScrollView(.horizontal)`，行 `.fixedSize(horizontal:true, vertical:false)` 不折行；**横滚只包正文区**，外层纵向 ScrollView + 520 横竖自适应布局不变（守 R2）。
- (c) `.textSelection(.enabled)`。
- (d) 字号 `caption2 → caption`/适度上调 + 行高。
**风险 R2**：横滚叠加 520 自适应可能嵌套滚动 → 横滚只包正文，外层不变，真机验嵌套手感（横竖屏各验）。
**测试**：接线/观感走真机验收。

## D8 / #9 — 审查发起可见反馈

**现状**：`ReviewTabView` 按钮 `Button { Task { _ = await activeConversation.startReview?(mode) } }`，Bool 返回被丢弃，面板内无反馈（D4 fire-and-forget）。
**方案**：`@State reviewFeedback: ...`；`startReview` 返回 Bool 后置短时可见态，在审查面板内以**连接横幅同款 Capsule 样式** inline 显示「审查已发起」，`~1.5s` 后由**一次性 `Task.sleep`** 收起（能耗有先例 ConversationView:156「单次挂起，无周期唤醒」）。不加「假防抖」`isStarting`，不改 D4 fire-and-forget 本质。
**风险**：一次性 sleep ≈ 0 持续成本，非轮询/定时器（守 energy-awareness）。
**测试**：接线项走模拟器/真机验收（点发起 → Capsule 提示短时出现后消失）。

## D9 / #10 — 近底阈值接入生产（真调策略函数）

**现状**：`ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:CGFloat=120)` 仅测试调用；生产用 `Color.clear.frame(height:1)` 1pt sentinel 的 onAppear/onDisappear 判近底（实为「贴底 1px」，非 120pt）。
**方案（决策 B）**：用 `GeometryReader` 测量滚动内容底部到可视底部的距离 `distanceToBottom`，喂给 `ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:120)`，由策略函数产出 `isNearBottom` → 消灭死代码。sentinel 从「判定真源」降为触发点/或移除，判定权归策略函数。iOS 17.0 部署目标排除 `onScrollGeometryChange`(iOS18) → 用 `GeometryReader` + `PreferenceKey` 在滚动内容内读取几何（事件驱动，随布局变化触发，非几何轮询/定时器）。
**风险 R1**：近底判定从 1px 放宽到 120pt 改自动滚手感 → 策略函数单一真源 + 单测锁阈值 + 真机横竖屏各验自动滚/新消息浮标手感。
**能耗**：`GeometryReader`/`PreferenceKey` 随布局变化事件驱动更新，无周期唤醒（守 energy-awareness）。
**测试**：`isNearBottom(distanceToBottom:threshold:)` 阈值单测（119→true、121→false、边界 120→true）；生产接入以真机验收确认自动滚/浮标。

## 恒定原则守卫

- **security-first**：本 change 不改 relay/E2E/transport/Keychain/security 符号；#5 仅本地化展示串，`.failed(String)` 契约不变。grep 核对零触碰安全符号（tasks 4.4）。
- **energy-awareness**：#7/#9/#10 均事件驱动，无新增轮询/定时器；#9/#10 的 `Task.sleep`/`GeometryReader` 为一次性/布局事件驱动（有项目先例）。
- **ui-adaptation-baseline**：#3/#4/#7/#8/#9/#10 涉 UI，横竖屏各验一遍；软/硬键盘不遮挡、可交互。

## 测试策略汇总

- **纯逻辑 XCTest**：#2 缓存失效复合键、#3 columnVisibilityPlan 穷举档位（含 lastRequested tiebreaker）、#10 isNearBottom 阈值、#5 无占位假串守卫 + 注入 locale 文案。
- **接线/观感（模拟器 + 真机）**：#4/#6/#7/#8/#9，横竖屏各验、软/硬键盘。
- 全量 iOS 测试绿（新增 + 既有回归不破）。

## OpenSpec Spec Patches（delta spec 写回）

全部以 **ADDED Requirements** 形式落 8 个 capability delta（自立新验收场景，无 MODIFIED 继承负担、规避归档丢场景陷阱）：
`ipad-review-panel`（#2 + #8-diff）、`ipad-right-panel-tabs`（#3）、`ipad-review-actions`（#4 + #9）、`ipad-localization`（#5）、`ipad-touch-accessibility`（#6）、`ipad-multi-connection`（#7）、`ipad-file-browser`（#8-file）、`ipad-conversation-ux`（#10）。
