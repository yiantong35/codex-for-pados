## ADDED Requirements

### Requirement: 摘要浮层可跳转到右栏审查面板
摘要浮层的「变更」入口 SHALL 能跳转到右栏审查面板：注入的跳转信号 SHALL 复用既有右栏 tab 选择意图（打开右栏并选中审查 tab），不得写入会话共享状态导致侧聊/主对话串台。跳转 chevron SHALL 在信号可用时可点击，不再恒 disabled。

#### Scenario: 点击摘要变更入口打开审查面板
- **WHEN** 用户在摘要浮层点击「变更」行的跳转 chevron
- **THEN** 右栏打开并选中审查 tab，展示当前工作区变更；不修改会话共享状态

#### Scenario: 跳转 chevron 可用
- **WHEN** 摘要浮层在具备跳转信号的上下文中呈现
- **THEN** 跳转 chevron 可点击（非 disabled）

### Requirement: 进度卡变更入口路由隔离
主工作区进度卡的变更文件入口 SHALL 打开右栏并选中 Review tab。Side Chat 中复用的对话视图 SHALL 不把该入口路由到主工作区 Review；无路由时文件统计 SHALL 为只读内容而非伪按钮。

#### Scenario: 主会话点击变更文件
- **WHEN** 用户点击主会话进度卡中的变更文件统计
- **THEN** 右栏打开并选中 Review tab

#### Scenario: Side Chat 不串台
- **WHEN** Side Chat 渲染包含 diff 的进度卡
- **THEN** 文件统计不触发主工作区导航，也不暴露无动作按钮语义

### Requirement: 发起审查给出可见反馈
在审查面板发起 AI 审查后 SHALL 给出短时可见反馈（发起态提示），基于发起调用的返回事件驱动。反馈 SHALL 为一次性短时呈现后自动收起，不引入轮询/周期定时器，不改变 fire-and-forget 的发起本质。

#### Scenario: 发起后短时提示
- **WHEN** 用户点击发起本轮/全量审查
- **THEN** 审查面板内短时显示「审查已发起」提示，随后自动收起

#### Scenario: 反馈不引入周期唤醒
- **WHEN** 发起反馈呈现与收起
- **THEN** 仅用一次性延时收起，无轮询或周期定时器

#### Scenario: 快速连点不重复发起
- **WHEN** 用户在一次提交与反馈周期内连续点击发起审查
- **THEN** 仅首次点击发起请求，按钮保持锁定直到反馈收起

#### Scenario: 发起失败明确反馈
- **WHEN** 发起回调返回失败
- **THEN** 面板短时显示本地化失败反馈，而非静默无响应
