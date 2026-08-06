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
