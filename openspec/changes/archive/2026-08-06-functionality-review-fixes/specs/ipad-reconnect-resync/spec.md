## ADDED Requirements

### Requirement: 重连后 thread/resume 权威对账重置运行态

重连后 `thread/resume` 快照包含 turn status 时，iPad MUST 以生成的官方状态集合权威收敛运行态：只有 `inProgress` SHALL 设置/保留 activeTurnId；`completed`、`interrupted`、`failed` MUST 清 activeTurnId、activeTurnKind 与 inFlightItemIds，并在清理后触发 outbox drain。未知未来 status MUST fail-safe 地视为非运行终态并记录诊断，MUST NOT 因未知字符串把 turn 恢复成运行中。

#### Scenario: interrupted 不恢复成运行中
- **WHEN** resume 最新 turn 的 status 为 `interrupted`
- **THEN** iPad 清理运行态、恢复 composer 非运行模式并补发符合条件的 outbox，不再显示永久生成中

#### Scenario: inProgress 保持运行
- **WHEN** resume 最新 turn 的 status 为 `inProgress`
- **THEN** iPad 以快照 turn id 校正 activeTurnId，继续显示运行态

#### Scenario: 未知状态不阻塞队列
- **WHEN** server 返回客户端尚不认识的非空 status
- **THEN** iPad 记录诊断并按终态清理，不让 outbox 永久阻塞
