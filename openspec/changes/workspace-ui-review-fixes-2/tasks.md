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
- [x] 2.3 #7 `TabBarView` 活动 tab 自动滚入可见：外套 `ScrollViewReader`，活动 tab `.id`，选中变化 `scrollTo(anchor:.center)`（事件驱动无定时器）。

## 3. P2–P3 可读性 / 反馈 / 死代码接入

- [x] 3.1 #8 diff 查看器可读性（`ReviewPanelView`）：行号 gutter + 长行横向滚动（不折行）+ `textSelection(.enabled)` + 字号/行高调优；横滚只包 diff 文本区，不破 520 横竖自适应。
- [x] 3.2 #8 文件查看器可读性（`FileBrowserView.contentArea`）：同上四项（行号/横滚/可选/字号行高）。
- [x] 3.3 #9 审查发起可见反馈：`ReviewTabView` 发起后给短时可见态（按钮态/inline/toast），基于回调返回事件驱动；不加假防抖、不改 D4 fire-and-forget。
- [x] 3.4 #10 近底阈值接入生产：让生产近底判定真正调用 `ScrollAnchorPolicy.isNearBottom(threshold:120)`（sentinel 1pt→120pt 近底带 或等价映射），消灭死代码；保持事件驱动；单测锁定阈值，真机验横竖屏自动滚/新消息浮标手感。

## 4. 验收与恒定原则守卫

- [ ] 4.1 全量 iOS 测试绿（新增单测 + 既有回归）；xcstrings 守卫测试通过。
- [ ] 4.2 `ui-adaptation-baseline`：#3/#4/#7/#8/#9/#10 涉 UI 项，横竖屏各验一遍；软键盘/外接键盘不遮挡、可交互。
- [ ] 4.3 `energy-awareness`：确认无新增轮询/定时器（#7/#9/#10 均事件驱动）。
- [ ] 4.4 安全面零触碰核对：grep 确认未改 relay/E2E/transport/Keychain/security 符号。
