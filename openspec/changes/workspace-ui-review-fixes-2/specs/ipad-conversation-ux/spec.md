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
