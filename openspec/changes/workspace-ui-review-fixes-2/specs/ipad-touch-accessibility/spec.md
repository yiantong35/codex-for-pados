## ADDED Requirements

### Requirement: 开关控件语义标签与点按控件 button trait
空可见标签的开关控件（如 `Toggle("").labelsHidden()`）SHALL 提供可被 VoiceOver 关联的 `accessibilityLabel`（如对应 skill 名）。以 `onTapGesture` 实现的点按控件 SHALL 暴露 button trait（`.accessibilityAddTraits(.isButton)` 或改用 `Button`），使辅助技术识别其可点按语义。

#### Scenario: 空标签开关具备语义标签
- **WHEN** VoiceOver 聚焦 SkillsGroupContent 中空标签的 skill 开关
- **THEN** 朗读出对应 skill 名，可关联开关与其含义

#### Scenario: 点按控件暴露 button trait
- **WHEN** VoiceOver 聚焦以手势实现的点按控件
- **THEN** 该控件被识别为按钮（具备 button trait）
