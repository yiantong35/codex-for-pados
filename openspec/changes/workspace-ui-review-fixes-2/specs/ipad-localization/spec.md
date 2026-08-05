## ADDED Requirements

### Requirement: 无占位假串且 Store 文案跟随注入 locale
面向用户的字符串 SHALL 为正确本地化文案，不得发布占位假串（如「帮紧你，帮紧你」）。Store 层面向用户的展示文案（连接失败/超时/信任撤销、目录加载失败等）SHALL 跟随应用内注入的 locale（经 `L10n.string(key, locale:)` 读取与注入同源的 locale），不得硬编码单一语言。开发者日志字符串不在此约束内。

#### Scenario: 无占位假串
- **WHEN** 校验本地化资源（xcstrings）与 Store 展示文案
- **THEN** 不存在占位玩笑串（如「帮紧你」），`conv.item.unknown` 为正确 en/zh 文案

#### Scenario: 切换英文后 Store 文案无残留中文
- **WHEN** 应用内注入 locale 切换为英文，触发连接失败/目录加载失败等展示文案
- **THEN** 展示为英文文案，无残留硬编码中文

#### Scenario: 展示契约不变
- **WHEN** 本地化 Store 展示文案
- **THEN** `.failed(String)` 等展示数据契约保持不变，仅文案随 locale 变化
