---
comet_change: workspace-ui-review-fixes
role: technical-design
canonical_spec: openspec
archived-with: 2026-08-05-workspace-ui-review-fixes
status: final
---

# Workspace UI Review Fixes — Technical Design

## 背景

一份外部 UI 方向 review 对 iPad `CodexRemote` 工作区提出 8 项发现（2 发布阻断 P1 + 4 P2 + 2 P3）。用户决定单一 change 一次性修复。全部改动落在 iOS 视图/Store 层，不触及 relay/E2E/传输层与安全面（SSH 已由 PR#46 移除，relay 为唯一路径）。

canonical spec 在 OpenSpec：7 个 delta capability spec（全 ADDED requirement）已在 comet-open 阶段建好并 `openspec validate --strict` 通过。本 Design Doc 只讲 HOW，不复述需求。

## 现状（已核码）

| 位置 | 事实 |
|---|---|
| `RootSplitView.swift:8,41,114` | `ActiveConversationHolder` 单例，RootSplitView 持有并 `.environment` 注入整棵树 |
| `ConversationView.swift:48-50,57,94-96,100` | `.task`/`onChange` 无条件写 holder，`onDisappear` 清空三者，`:100` 调 `connection.setResumeHandler`（单属性覆盖） |
| `SideChatView.swift:72` | 复用同一 `ConversationView(threadId:)` → 侧聊与主对话共写同一 holder、同一 resumeHandler |
| `RightPanelContainerView.swift:85-89` | 已有注释承认全屏 base/cover 双挂载会 clobber，以「全屏态 base 只留背景」规避；**常规态**侧聊仍共享 holder（本 change 根治处，PR#25 未覆盖） |
| `RightPanelContainerView.swift:140` | 每 tab 标签 `.frame(maxWidth:.infinity)` + 尾部定宽全屏按钮 → 窄宽首标签占满、后两 tab 被裁 |
| `ConnectionStore.swift:94,124,132,400` | `resumeHandler` 单可选属性；`setResumeHandler` 直接赋值 + `triggerInitialRejoinIfReady`（`didInitialRejoin` 保证恰一次）；`:400` 物理重连 `.ready` 调 handler |
| `WorkspaceMetrics.swift:35,62` | 注释自陈三栏最低宽 `160+280+200+28=668`；`clampColumnWidth` 用 `max(columnMin, upper)` **永不低于 columnMin** → 容器 <668 时列宽和 > 容器 → HStack 溢出 |
| `ShortcutsSettingsSectionView.swift:119-133` | **已有正确的跟随注入 locale 写法**：`Bundle.main.path(forResource: locale.identifier, ofType:"lproj")` → `bundle.localizedString(forKey:value:table:)` + 语言码 + Bundle.main 三级 fallback |
| `OrientationSnapshotTests.swift:254` | 仅断言快照 PNG 非空 → 结构性无法捕获 tab 裁剪/溢出（P1#2 逃逸根因） |

## 目标 / 非目标

**目标**：修复 8 项发现（见下 9 决策）+ 收口测试盲区。守项目三恒定原则：安全（本 change 不碰安全面）、UI 三基线（横竖屏 + 手势/软键盘/外接键盘）、能耗（无新增轮询/定时器）。

**非目标**：不新增功能；不碰 relay/E2E/传输/安全面；不重构三栏架构本体（仅补窄窗降级）；不改侧聊 fork/多侧聊既有语义（仅隔离其审查状态写入）。

## 决策

### D1 侧聊状态隔离 — `ConversationView` 增工作区绑定开关
`ConversationView` 增显式参数 `bindsWorkspaceState: Bool`（默认 true），侧聊挂载（`SideChatView.swift:72`）传 false。仅 `bindsWorkspaceState == true` 时才写 `activeConversation.{state,fetchFullDiff,startReview}` 并在 `onDisappear` 清空、并归属 resume 注册；侧聊实例完全不碰 holder。

`ActiveConversationHolder` 仍是单例——审查面板读的是环境里的单例 holder，只让「主对话」这一路写它，天然保证「审查/diff 恒反映主对话」，且侧聊开/关不覆盖不清空。

**备选**：①给侧聊注入独立 holder——审查面板反而读不到主对话，更绕；②holder 里 main/side 双槽——过度设计。均劣。

### D2 resume 回调多订阅 — `ConnectionStore` 单属性 → token 订阅表
`resumeHandler` 改为 `[Token: @Sendable () async -> Void]`（Token 轻量唯一标识）：
- `addResumeHandler(_:) -> Token`：登记并返回 token；若当前已 `isReady` 且该 token 未触发过，补触发恰一次。
- `removeResumeHandler(_ token:)`：精确注销。
- 物理重连 `.ready`（`:400`）：遍历触发全部订阅者。
- `didInitialRejoin` 语义**订阅者维度化**（记录哪些 token 已首连触发过），新订阅者不漏触发、老订阅者不重触发。

`ConversationView.task` 生命周期承载 add→（`onDisappear`/`defer`）remove 配对（仅 `bindsWorkspaceState` 与侧聊各自 thread 的 rejoin 都需要，故多订阅）。`setResumeHandler` 保留为薄封装（内部 add，忽略返回 token）或全量迁移调用点。

只把「一个→多个」，不改触发时机。

### D3 右栏 tab 窄宽可达 — 去每标签 `maxWidth:.infinity` 独占
tab 切换条改为可容纳全部入口：标签用等分/压缩（`.layoutPriority` + `.minimumScaleFactor` 或 `fixedSize` 不独占），宽度不足时横向可滚动或文字降级为图标；尾部全屏入口不参与 tab 等分、固定占位、不挤占 tab 命中区。断言三 tab 在 320pt 均可命中。

**备选**：仅缩小字体——极窄仍溢出；横向滚动/降级更稳。

### D4 窄窗三栏降级 — 自动收起侧栏（用户已选 A）
`WorkspaceMetrics` 增「三栏全开最低宽 668」常量 + 降级决策**纯函数**（输入容器宽 → 应显示哪些栏）。`ResizableColumns` 在容器 < 阈值时自动收起右栏（再不够收左栏），保证渲染宽度之和 ≤ 容器宽、中栏永远完整。收起的侧栏保留既有列宽持久化，宽度恢复后（≥ 阈值）可再展开。

降级发生在「显示哪些栏」层而非「每栏多宽」层（`clampColumnWidth` 的 `max(columnMin, upper)` 兜底是溢出根因）。断点用物理下界 668pt，远离常见全屏尺寸，避免临界抖动；恢复用同一阈值。

**非 overlay**（用户已明确排除 B/C）——overlay 列为将来可选，本 change 不做。

### D5 i18n 跟随注入 locale — 抽共享 helper 复用既有正确写法
项目已有正确通道（`ShortcutsSettingsSectionView.swift:119-133`）：按 `@Environment(\.locale)` 的 `locale.identifier` 查对应 `.lproj` bundle → `bundle.localizedString(forKey:value:table:)`，带语言码 + `Bundle.main` 三级 fallback。已知反例 `String(localized:)` 只影响插值格式化、不切 strings 表 → 读系统语言忽略应用内语言（bug）。

本 change：把该逻辑**抽成共享 helper**（如 `Bundle.localized(_:locale:)` 或 `EnvironmentValues` 扩展），供 FileBrowserView / ReviewPanelTypes / ShortcutsSettingsSectionView 及动态标签（右栏 tab label、审查模式名）复用；硬编码中文改走此 helper；`Localizable.xcstrings` 补键。无新机制。

### D6 删机器确认 — confirmationDialog + 菜单状态互斥
`TabBarView` 移除项包 `confirmationDialog`（`role: .destructive`），确认后才调 `SessionsManager` 删除。管理菜单按连接态条件渲染「连接」XOR「断开」（互斥由单一连接态推导），消除断开态同时显示两者。

### D7 触控 / 辅助功能 — 命中框 + 语义标签 + 按钮语义
图标按钮（ComposerView 图片/模型/停止/发送等）统一 `.frame(minWidth:44,minHeight:44)`（或 `.contentShape` + padding 保证 ≥44pt 命中区）+ `.accessibilityLabel`；`SidebarView` 会话行 `onTapGesture` → `Button`（获 button trait + 键盘激活），保留既有视觉。

### D8 空态 + 滚动位置感知
`RootSplitView` detail 未选会话时渲染 `split.selectConversation` 文案引导空态。`ConversationView` 用 `ScrollViewReader` + 近底判定（记录用户是否接近底部）：仅近底时 `onChange` 自动滚，否则不滚并显「新消息」浮标，点按滚到底。近底判定用可见性/偏移量估计，纯 UI 状态，无常驻轮询（守能耗）。

### D9 测试盲区收口
`OrientationSnapshotTests`（`:254`）由「PNG 非空」升级为对右栏 tab 可见性/命中与窄窗不溢出的结构断言（或新增专门测试）；新增侧聊隔离（侧聊实例不写 holder）、resume 多订阅（add/remove/补触发）、滚动位置感知单测。无断言的快照测试正是 P1#2 逃逸根因。

## 风险 / 取舍

- **D2 触及重连核心路径** → 保留 `didInitialRejoin` 恰一次语义（订阅者维度化），补单测覆盖首连补触发/重连遍历/注销后不触发；只改数量不改时机。
- **D1 遗漏写点** → 单一 `bindsWorkspaceState` 开关收口全部写点（state/fetchFullDiff/startReview/onDisappear/resume 归属五处统一 gate），单测断言侧聊实例零写入。
- **D4 断点抖动** → 物理下界 668pt，恢复同阈值。
- **UI 三基线**（`ui-adaptation-baseline`）→ 每个碰 UI 的 task 验收覆盖横竖屏 + 手势/软键盘/外接键盘。
- **能耗**（`energy-awareness-principle`）→ 滚动感知/降级纯 UI 状态、事件驱动，无新增轮询/定时器。

## 迁移计划

无数据/协议迁移，纯 iOS UI 层。回滚 = 还原视图/Store 改动（无持久化 schema 变更）。分批推进：批1 两 P1 阻断（D1+D2+D3）→ 批2 P2（D4+D5+D6+D7）→ 批3 P3（D8）+ 测试收口（D9），每批可独立测试。

## 开放问题

- 无。原「跟随注入 locale 的 helper 是什么」已由代码探明（`ShortcutsSettingsSectionView.swift:119`）；原「D4 收起 vs overlay」用户已选自动收起（A）。
