# Tasks — workspace-ui-review-fixes-2

> 基线 `ee22d660`。每条以「生产路径可见行为」为验收准绳（首轮教训：孤立函数测过≠生产接入）。
> 守 `ui-adaptation-baseline`（横竖屏+手势+软/硬键盘）与 `energy-awareness`（事件驱动、无新增轮询/定时器）。

## 1. P1 清晰缺陷（correctness / release-blocking）

- [x] 1.1 #2 `ReviewTabView` 全量 diff 缓存按 `cwd`(+thread) 失效：`.task(id:)` 绑 `mode+cwd` 复合键，cwd 变化即清空 `fullDiff` 重取；补单测覆盖「切 thread 后不复用旧工作区 diff」。
- [x] 1.2 #3 `WorkspaceMetrics.columnVisibilityPlan` 窄窗档位修正：`wantRight` 为真或总宽落在 center+right 可容纳档时据实展开右栏，不再 `wantLeft` 一票 `showRight:false`；穷举 320/494/668/宽档单测，含首轮 D3/D4 既有场景不回归。
- [x] 1.3 #5 消除占位假串与硬编码中文：`conv.item.unknown` en/zh 换正确本地化文案；`ConnectionStore:432`、`FileBrowserStore:103` 等改 `String(localized:)` 跟随注入 locale；补「xcstrings 无占位假串（无『帮紧你』等）」守卫测试。

## 2. P2 接线 / 完成（wiring & completion）

- [x] 2.1 #4 接线摘要→审查跳转：`RootSplitView` 向 `SummaryPopoverView` 注入 `onOpenReview`（复用右栏 tab 选择只读信号，不写共享 ActiveConversationHolder）；chevron 不再恒 `.disabled`，点击切到右栏审查 tab；删「后续接」注释。
- [x] 2.2 #6 a11y 补全：`SkillsGroupContent` 空 `Toggle` 补 `accessibilityLabel(skill 名)`；同类空标签开关一并补；点按控件（onTapGesture 类）补 button trait；VoiceOver 朗读校验。
- [x] 2.2b #6 补漏（verify 发现）：`ProgressCardBar` 仅在存在 plan 时提供原生展开 `Button`，diff-only 状态不暴露无动作的伪按钮；文件统计仅在具备 Review 路由时为按钮。两类按钮均具备 44pt 命中区与动态 VoiceOver 标签。
- [x] 2.3 #7 `TabBarView` 活动 tab 自动滚入可见：外套 `ScrollViewReader`，活动 tab `.id`，选中变化 `scrollTo(anchor:.center)`（事件驱动无定时器）。

## 3. P2–P3 可读性 / 反馈 / 死代码接入

- [x] 3.1 #8 diff 查看器可读性（`ReviewPanelView`）：行号 gutter + 长行横向滚动（不折行）+ `textSelection(.enabled)` + 字号/行高调优；横滚只包 diff 文本区，不破 520 横竖自适应。
- [x] 3.2 #8 文件查看器可读性（`FileBrowserView.contentArea`）：同上四项（行号/横滚/可选/字号行高）。
- [x] 3.3 #9 审查发起可见反馈：`ReviewTabView` 发起后给短时可见态（按钮态/inline/toast），基于回调返回事件驱动；不加假防抖、不改 D4 fire-and-forget。
- [x] 3.4 #10 近底阈值接入生产：让生产近底判定真正调用 `ScrollAnchorPolicy.isNearBottom(threshold:120)`（sentinel 1pt→120pt 近底带 或等价映射），消灭死代码；保持事件驱动；单测锁定阈值，真机验横竖屏自动滚/新消息浮标手感。

## 4. 验收与恒定原则守卫

- [x] 4.1 全量 iOS 测试绿（新增单测 + 既有回归）；xcstrings 守卫测试通过。最终结果：697 tests、0 failures、0 skipped。
- [x] 4.2 `ui-adaptation-baseline`：代码级横竖屏适配已守（ReviewPanel/FileBrowser 520 阈值横竖自适应、TabBar ScrollViewReader 手势保留、ConversationView GeometryReader 全屏自适应；audit 确认未破）。真机横竖屏 + 软/硬键盘手感终验由用户在 iPad Pro 11" 完成（同各任务 device-acceptance 步，非静默略过）。
- [x] 4.3 `energy-awareness`：确认无新增轮询/定时器；diff 仅出现 #9 一次性 `Task.sleep(1_500_000_000)`（无循环包裹），#7/#10 纯事件驱动（onChange/onPreferenceChange）。
- [x] 4.4 安全面零触碰核对：改动 15 文件均 UI/展示/store-展示串；无 relay/E2E/transport/Keychain/security 逻辑文件；ConnectionStore diff 无 connLog/Ed25519/X25519/TOFU/handshake/transportFactory/Keychain 行。

## 5. 恢复构建后的全面 UI/UX 收口

- [x] 5.1 进度卡「变更文件」入口通过显式回调统一打开右栏 Review tab；主会话可路由，Side Chat 即使误传回调也被隔离策略阻断；移除 `ActiveConversationHolder.requestRightPanel` 布尔旁路。
- [x] 5.2 AI Review 提交增加 1.5 秒提交门闩，快速连点不再重复发起；成功与失败均显示 inline 反馈，反馈期间按钮锁定并显示进度态。
- [x] 5.3 动态本地化扫尾：配对错误、审批回退、Composer 数字、侧栏相对时间、摘要子智能体状态、账户限额/重置时间显式跟随注入 locale。
- [x] 5.4 全局触控/无障碍扫尾：顶栏、右栏 tabs、文件树、Side Chat 与机器 tab 达到 44pt；机器状态使用不同符号+颜色+VoiceOver value；Reduce Motion 关闭脉冲与非必要过渡。
- [x] 5.5 `<494pt` 紧凑宽度右栏改为 280pt（受容器约束）覆盖层，保留中栏上下文；中间档隐藏右栏的首次点击立即聚焦右栏，无需双击。

## 6. 最终验证

- [x] 6.1 Comet/OpenSpec 严格校验、全量 iOS 测试、Debug build、模拟器安装/启动与关键快照检查全部通过；MobAI 因设备额度 402 不可用，已记录并以同一 iPad 模拟器的 simctl 安装/启动/截图替代。
