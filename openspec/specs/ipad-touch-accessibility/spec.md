# ipad-touch-accessibility Specification

## Purpose
TBD - created by archiving change workspace-ui-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 核心操作控件的触控命中框与语义标签

核心操作的图标按钮（至少包括发送、停止、图片选择、模型选择）SHALL 提供不小于 44×44pt 的触控命中框，并 SHALL 提供语义化的辅助功能标签（accessibility label），使 VoiceOver 可朗读其用途。这些控件 SHALL 可被触控点击、指针点击与外接键盘激活。

#### Scenario: 图标按钮满足最小命中框
- **WHEN** 渲染发送/停止/图片/模型等图标按钮
- **THEN** 每个按钮的可命中区域 SHALL 不小于 44×44pt

#### Scenario: 图标按钮具备语义标签
- **WHEN** VoiceOver 聚焦到某图标按钮
- **THEN** SHALL 朗读出描述其用途的语义标签（非空、非仅图标名）

### Requirement: 列表行使用按钮语义而非裸手势

可点击的列表行（至少包括左侧会话/线程列表行）SHALL 采用按钮语义（具备 button accessibility trait 且可由键盘/指针激活），SHALL NOT 仅以裸 `onTapGesture` 承载点击——后者不获得按钮 trait 也不支持键盘激活。

#### Scenario: 会话行具备按钮 trait
- **WHEN** VoiceOver 聚焦到某会话/线程列表行
- **THEN** 该行 SHALL 暴露 button trait
- **AND** SHALL 可由外接键盘（回车/空格）激活选中该会话

### Requirement: 开关控件语义标签与点按控件 button trait
空可见标签的开关控件（如 `Toggle("").labelsHidden()`）SHALL 提供可被 VoiceOver 关联的 `accessibilityLabel`（如对应 skill 名）。以 `onTapGesture` 实现的点按控件 SHALL 暴露 button trait（`.accessibilityAddTraits(.isButton)` 或改用 `Button`），使辅助技术识别其可点按语义。

#### Scenario: 空标签开关具备语义标签
- **WHEN** VoiceOver 聚焦 SkillsGroupContent 中空标签的 skill 开关
- **THEN** 朗读出对应 skill 名，可关联开关与其含义

#### Scenario: 点按控件暴露 button trait
- **WHEN** VoiceOver 聚焦以手势实现的点按控件
- **THEN** 该控件被识别为按钮（具备 button trait）

### Requirement: 主要控件命中区与状态表达
顶栏图标、右栏 tab/全屏、文件树、Side Chat、机器 tab 与进度卡交互控件 SHALL 具备至少 44×44pt 命中区。机器状态 SHALL 同时使用不同符号与本地化 VoiceOver value，不得只靠颜色；闪烁 SHALL 尊重 Reduce Motion。

#### Scenario: 主要图标控件易于触控
- **WHEN** 用户触控顶栏、右栏、文件树或 Side Chat 的主要操作
- **THEN** 可用命中区至少为 44×44pt，且不会因窄宽互相遮挡

#### Scenario: 状态不只依赖颜色
- **WHEN** 机器处于未读、运行、需处理、错误或断连状态
- **THEN** 状态使用不同符号并提供本地化 VoiceOver value

#### Scenario: Reduce Motion 停止脉冲
- **WHEN** 系统开启 Reduce Motion
- **THEN** attention/error 状态不执行无限透明度脉冲动画
