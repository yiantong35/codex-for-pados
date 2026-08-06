# Brainstorm Summary

- Change: workspace-ui-review-fixes-2
- Date: 2026-08-05

## Confirmed Technical Approach

按 D1–D9 逐条落地，全部以「生产路径可见行为」为验收准绳（守 R5：孤立函数测过≠接入）。

- **D1 / #2 缓存失效**：`ReviewTabView` 全量 diff 缓存键 `mode` → `mode + cwd` 复合键。`.task(id:)` 绑复合键；cwd（取自选中 thread）变即把 `fullDiff` 置空并重取。纯状态推导，单测锁定「切 thread 后不复用旧工作区 diff」。
- **D2 / #3 窄窗档位**：`columnVisibilityPlan` 增加「最后请求侧」tiebreaker 参数（`.left/.right/none`）。物理档位（常量实测）：≥668 两栏均尊重；[494,668) 左+中 与 中+右 各自可容纳但不能同时 → 按最后请求侧决定展开哪一侧（消除 494–667 档右栏死按钮）；[454,494) 仅左+中可容纳；<454 仅中栏。`WorkspaceLayoutStore` 记录最近一次被打开的侧栏。R3：穷举 320/454/494/668/宽档单测，且不回归首轮 D3/D4 P1#2（右栏三 tab 在窄档仍可达——依赖对 caller 的核实，见 pending）。
- **D3 / #4 导航接线**：`RootSplitView` 构造 `SummaryPopoverView` 时注入 `onOpenReview: { layout.requestRightPanel(.review) }`，复用既有 `RightPanelIntent` 意图载体（`WorkspaceLayoutStore.requestRightPanel` 置 `showRight=true` + `pendingRightPanelIntent=.review`）。不写 `ActiveConversationHolder`，规避 R4 状态串台。`SummaryPopoverView.onOpenReview` 形参与 `.disabled(onOpenReview==nil)` 已就位，仅需 caller 传值；删「后续接」注释。
- **D4 / #5 i18n**：`conv.item.unknown` en/zh 换正确文案（消灭占位假串「帮紧你，帮紧你」）。`ConnectionStore`/`FileBrowserStore` 面向用户串改走 `L10n.string(key, locale: LocaleManager.currentLocale)`（新增静态 `LocaleManager.currentLocale`，读同一 UserDefaults `app_language`，与注入 locale 同源）。**不用 `String(localized:)`**（它按系统语言选表、忽略应用内注入 locale）。严格区分用户可见串（localize）与开发者日志 `connLog.*`（不碰）；`.failed(String)` 枚举契约不变（外科式，不触 relay 逻辑）。补「xcstrings 无占位假串」守卫测试。
- **D5 / #6 a11y**：`SkillsGroupContent` 空 `Toggle("",…).labelsHidden()` 补 `.accessibilityLabel(Text(skill.name))`；同类空标签开关一并补；`onTapGesture` 类点按控件补 `.accessibilityAddTraits(.isButton)`。
- **D6 / #7 tab 自动滚**：`TabBarView` 外套 `ScrollViewReader`，每个 tab `.id(machine.id)`，`onChange(of: activeSessionId) { withAnimation { proxy.scrollTo(id, anchor:.center) } }`。事件驱动无定时器。
- **D7 / #8 可读性（diff + 文件）**：四项——行号 gutter、长行横向 `ScrollView(.horizontal)` 不折行、`.textSelection(.enabled)`、字号/行高上调。横滚只包文本区，外层纵向/自适应布局不变（守 R2、520 横竖自适应不破）。（具体 caller/容器结构待 agent 核实。）
- **D8 / #9 可见反馈**：`ReviewTabView` 发起审查后给短时可见态，基于 `startReview` 的 Bool 返回值驱动（当前返回被丢弃）。用一次性 `Task.sleep` 定时收起——项目已有先例（ConversationView:156 单次挂起注明「无周期唤醒（能耗）」），守 energy-awareness。不加假防抖、不改 D4 fire-and-forget 本质。
- **D9 / #10 阈值接入**：让生产近底判定真正调用 `ScrollAnchorPolicy.isNearBottom(threshold:120)`，消灭死代码。iOS 17.0 部署目标排除 `onScrollGeometryChange`(iOS18)。两个候选取法（1c 决策点）：A) 把 sentinel 从 1pt 高改为 120pt 近底带，`onAppear` 即「进入近底 120pt」——几何无关、最省，但语义等价而非真调函数；B) `GeometryReader` 喂 `distanceToBottom` 给 `isNearBottom(distanceToBottom:threshold:)` 真调策略函数——真消灭死代码但引入几何读取。设计倾向 B（D9 明确要求"真正调用该策略函数"），以单测锁阈值 + 真机横竖屏验自动滚/浮标手感（R1）。

## Key Trade-offs and Risks

- R1 #10 语义偏移：近底判定放宽可能改自动滚手感 → 策略函数单一真源 + 单测锁阈值 + 真机横竖屏各验。
- R2 #8 横滚 vs 横竖屏自适应：横滚只包 diff 文本区，外层不变，真机验嵌套滚动手感。
- R3 #3 档位回归：穷举档位单测 + 保首轮 D3/D4 P1#2 窄档右栏可达（依赖 caller 核实）。
- R4 #4 状态串台：复用只读跳转意图（requestRightPanel），不写共享 holder。
- R5 过度声称复发：每条以生产路径可见行为验收，接线项真机/模拟器眼见。

## Testing Strategy

- 纯逻辑 XCTest：#2 缓存失效复合键、#3 columnVisibilityPlan 穷举档位（含 tiebreaker）、#10 isNearBottom 阈值、#5 本地化键存在性 + 无占位假串守卫。
- 接线/观感：#4/#6/#7/#8/#9 走模拟器 + 真机验收（横竖屏各一遍，软/硬键盘不遮挡）。
- 全量 iOS 测试绿（新增 + 既有回归不破）。

## Spec Patches

待定：若 delta spec 缺验收场景（尤其 #3 档位、#10 阈值、#2 失效），在对应 `specs/<capability>/spec.md` 补充边界验收场景（仅补场景/纠歧义/加边界，不重写结构）。归档时守 MODIFIED-scenario 继承铁律（逐个继承现存 scenario；改名=丢场景 abort；废弃需 REMOVED+ADDED）。

## 核实结论（agent）

- **#3 caller**：唯一调用点 `ResizableColumns.swift:38-39`（body 内 GeometryReader）。`total`←`proxy.size.width`；`wantLeft`←`layout.leftVisible`(默认 true)；`wantRight`←`layout.showRight`(默认 false)。showLeft/showRight 仅条件渲染左右栏，隐藏栏宽记 0，**无 swap/overlay/sheet/center-replacement**。
- **⚠️ R3 反转发现**：`total<494` 时右栏**完全不可达**——无任何 fallback。`RightPanelContainerView` 的 `.fullScreenCover` 定义在其内部，而它仅在 `if effRightVisible { right() }` 内挂载 → showRight 被过滤成 false 时该 view 根本不入树，全屏逃生与 `pendingRightPanelIntent` 消费者均不触发。即：**320pt Split View 下右栏本就打不开**（既有 gap，非本轮 review #3 所报）。推论：scoped #3 修复只治 [494,668)；320pt 下 #4 摘要→审查跳转（requestRightPanel 置 showRight=true）仍会静默失败。→ 升为 1c 决策点。
- **#8 内部**：ReviewPanelView & FileBrowserView 均 threshold=520 横竖自适应；diff/文件正文都是 `Text` + `.system(.caption2,.monospaced)` + `maxWidth:.infinity` 无 `lineLimit`（长行**软换行**）+ 纵向-only ScrollView；**无 gutter、无横滚、无 textSelection**。可复用先例：`ItemCards.swift:265-277` 逐行 split-by-`\n` 的可选 monospaced diff（唯一 selectable 先例）。全库无行号 gutter、无「横滚承载代码」先例。

## 1c 决策点定稿（用户确认）

- **#10 → B**：生产用 `GeometryReader` 量 `distanceToBottom` 喂 `ScrollAnchorPolicy.isNearBottom(distanceToBottom:threshold:120)`，真正调用策略函数、消灭死代码（仍事件驱动、无轮询）。sentinel 从「唯一真源」降为触发点，判定权归策略函数。
- **#3 → (a) scoped**：只修分屏 [494,668) 档死按钮（tiebreaker=最后请求侧）。iPad Pro 11" 全屏（竖 834/横 1194，均>668）三栏永远齐全、不受影响。**<494pt 超窄档右栏不可达属既有 gap，登记 BACKLOG，不在本轮**（避免范围蔓延 + 新全屏机制）。
- **#9 → Capsule inline 提示条**：复用连接横幅（CodexRemoteApp.swift:154 `reconnectBanner` 的 Capsule 样式）在审查面板内短时显示「审查已发起」，~1.5s 一次性 Task.sleep 收起。**不引入 toast**（全 app 现零 toast，引入全局 toast 应另开 change）。基于 `startReview` Bool 返回值驱动，不改 D4 fire-and-forget。

## Pending

- （无阻塞，已全部定稿；#3 320pt 超窄档 gap → 待办登记 BACKLOG）
