## ADDED Requirements

### Requirement: 活动机器 tab 自动滚入可见区
机器 tab 栏 SHALL 在活动 session 变化时把活动 tab 自动滚入可见区（居中），使活动 tab 不停留在离屏位置。滚动 SHALL 事件驱动（随活动 session 变化触发），不得引入轮询或周期定时器。

#### Scenario: 切换到离屏 tab 自动滚入
- **WHEN** 活动 session 切换到当前不在可视范围的机器 tab
- **THEN** tab 栏自动滚动使该活动 tab 居中可见

#### Scenario: 自动滚动事件驱动
- **WHEN** 活动 tab 自动滚入
- **THEN** 仅由活动 session 变化事件触发，无轮询或周期定时器
