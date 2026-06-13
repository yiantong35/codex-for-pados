## MODIFIED Requirements

### Requirement: 主界面布局可隐藏 inspector 且设置常显
连接就绪后的主界面 SHALL 将「环境信息/摘要」以**悬浮浮层**呈现（由顶部工具栏摘要按钮 `:≡` 切换），而非占整列的 inspector；整体布局遵循 `workspace-layout` 能力（五窗口 + 顶部固定工具栏）。全局设置入口 SHALL 在主界面始终可见。

> 变更说明：v1 曾把环境信息做成可隐藏的占列 inspector（顶栏切换）。本 change 改为：环境信息归入「摘要」悬浮浮层，inspector 占列让位给 `workspace-layout` 的右边栏（承载 Diff/文件/终端等，后续 change 填充）。布局/面板显隐规则统一由 `workspace-layout` 定义。

#### Scenario: 进入主界面默认聚焦侧栏
- **WHEN** 连接进入 ready 状态进入主界面且未选中任何对话
- **THEN** 默认聚焦左侧栏（项目/对话），摘要浮层与右/下栏默认隐藏
- **AND** 中栏不显示大占位卡

#### Scenario: 切换摘要浮层显隐
- **WHEN** 用户点击顶栏摘要按钮（`:≡`）
- **THEN** 摘要悬浮浮层在显示与隐藏之间切换（内容自适应，非整列）

#### Scenario: 主界面保留全局设置入口
- **WHEN** 连接就绪进入主界面（任何面板显隐组合）
- **THEN** 全局设置入口始终可见可用
