# ipad-localization Specification

## Purpose
TBD - created by archiving change workspace-ui-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 面向用户文案跟随注入的应用 locale

所有面向用户的文案 SHALL 跟随应用内注入的 locale（app 内语言切换），SHALL NOT 硬编码某一自然语言，也 SHALL NOT 使用不跟随注入 locale 的本地化 API。当用户在 app 内切换到英文时，文件浏览、侧聊、审查模式等界面 SHALL 全部呈现对应语言、SHALL NOT 出现中英混排。

已知约束：`String(localized:)` 在本项目中不跟随注入的应用 locale（见既有教训），故动态标签等 SHALL 采用跟随注入 locale 的方式（如从 environment locale 解析或经统一本地化入口），使切换即时生效。

#### Scenario: 切换英文后无残留中文
- **WHEN** 用户在 app 内将语言切换为英文
- **THEN** 文件浏览/侧聊/审查模式等界面文案 SHALL 全部为英文
- **AND** SHALL NOT 出现硬编码中文残留（无中英混排）

#### Scenario: 动态标签跟随注入 locale
- **WHEN** 界面中的动态标签（如右栏 tab 标签、审查模式名）在注入 locale 变化后重新呈现
- **THEN** 该标签 SHALL 反映当前注入的应用 locale
- **AND** SHALL NOT 停留在编译期默认语言

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

#### Scenario: 动态格式化跟随应用内语言
- **WHEN** 应用内语言切换后生成配对错误、审批回退、图片大小、相对时间、子智能体状态或限额重置文案
- **THEN** 文案与数字/时间格式使用当前注入 locale，不残留切换前语言
