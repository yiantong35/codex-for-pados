# ipad-conversation-ux Specification

## Purpose
TBD - created by archiving change workspace-ui-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 未选会话时主区呈现引导空态

当主区（中栏 detail）没有选中会话时，系统 SHALL 呈现引导性空态（复用既有 `split.selectConversation` 文案）指引用户下一步操作，SHALL NOT 仅渲染纯背景色导致用户无从判断。

#### Scenario: 未选会话显示引导
- **WHEN** 主区没有选中任何会话
- **THEN** SHALL 呈现 `split.selectConversation` 引导文案（而非纯背景）

#### Scenario: 选中会话后引导让位
- **WHEN** 用户选中一个会话
- **THEN** 引导空态 SHALL 让位给该会话的对话内容

### Requirement: 对话滚动位置感知

对话流 SHALL 仅在用户**接近底部**时于新内容到达（新 item / 运行态变化）自动滚到底；当用户已向上滚动阅读历史时，新内容到达 SHALL NOT 强制拉回底部打断阅读。此时系统 SHALL 提供一个「新消息」入口，用户点按后 SHALL 滚到底。

#### Scenario: 近底部时自动滚到底
- **WHEN** 用户视图接近对话底部，此时到达新 item 或运行态变化
- **THEN** 对话 SHALL 自动滚到底以跟随最新内容

#### Scenario: 上翻阅读时不打断
- **WHEN** 用户已向上滚动阅读历史，此时到达新内容
- **THEN** 对话 SHALL NOT 强制拉回底部
- **AND** SHALL 呈现「新消息」入口

#### Scenario: 点按新消息入口滚到底
- **WHEN** 用户在存在「新消息」入口时点按它
- **THEN** 对话 SHALL 滚到底并隐藏该入口

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
### Requirement: 对话滚动位置感知

对话流 SHALL 以 120pt 近底阈值判断是否跟随，并对所有可见内容增长生效：新增 item、既有 item 的流式文本增长、审批卡新增/恢复、运行态指示变化。近底时内容增长 SHALL 自动滚到真实 bottom sentinel；离底时 SHALL 保持阅读位置并显示新消息入口。用户点按入口也 MUST 滚到 bottom sentinel，不能停在 last item 或审批卡上方。实现 MUST 事件驱动，不新增 timer/轮询。

#### Scenario: 流式文本增长近底自动跟随
- **WHEN** 用户距底不超过 120pt，agent delta 持续增长同一个 item 的文本
- **THEN** 对话持续跟随真实底部，即使 items.count 不变

#### Scenario: 审批卡出现时可达
- **WHEN** 审批卡加入当前线程且用户近底
- **THEN** 对话滚到审批卡之后的 bottom sentinel，卡片完整可见

#### Scenario: 离底时内容增长只提示
- **WHEN** 用户距底超过 120pt，流式文本或审批卡使内容增长
- **THEN** 阅读位置不被拉走，并显示新消息入口；点击后滚到真实底部

### Requirement: 图片附件异步选择不被迟到结果覆盖

Composer SHALL 取消已被新选择、删除、发送或视图退出取代的图片加载/编码任务，并在写回前校验 selection token。旧图片编码晚于新图片完成时 MUST NOT 覆盖新选择；用户删除附件后，迟到任务 MUST NOT 重新挂回附件。编码器 SHALL 在耗时阶段响应 cancellation。

#### Scenario: 快速选择后保留最后选择
- **WHEN** 用户先选 A 后快速选 B，且 A 的编码最后完成
- **THEN** Composer 最终只展示 B，A 的迟到结果被丢弃

#### Scenario: 删除期间编码不回挂
- **WHEN** 图片仍在编码时用户删除附件
- **THEN** 任务被取消或结果因 token 失效被丢弃，附件保持为空
