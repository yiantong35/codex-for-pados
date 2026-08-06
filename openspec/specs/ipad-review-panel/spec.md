# ipad-review-panel Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: iPad 通用 diff 数据源

审查面板 SHALL 支持本轮 turn diff 与全量工作区 diff。全量 diff MUST 作为带 context identity 与 generation 的 snapshot 管理，identity 至少包含 cwd、threadId 与 RPC 身份；任一变化 MUST 立即使旧 snapshot 失效并重取。异步请求返回时 MUST 再次比对 identity/generation，迟到结果不得写入新工作区。由于同 cwd 的外部文件修改不一定产生可靠通知，面板 MUST 提供显式刷新入口；发起全量 AI 审查前 MUST 刷新当前 snapshot，使可见 diff 与动作上下文一致。

#### Scenario: 切线程丢弃迟到 diff
- **WHEN** 工作区 A 的 fetch 尚未完成时切到工作区 B，随后 A 结果迟到
- **THEN** A 结果被丢弃，面板只显示 B 的 snapshot

#### Scenario: 同 cwd 修改后显式刷新
- **WHEN** 同一 cwd 的文件在首次加载后再次变化
- **THEN** 用户可刷新并看到新 diff，不永久复用首次缓存

#### Scenario: 发起全量审查与展示一致
- **WHEN** 用户在 full 模式点击发起审查
- **THEN** 面板先刷新当前 context snapshot，再启动 review；不得展示旧 diff 却审查新 cwd
