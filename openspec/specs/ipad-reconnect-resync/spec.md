# ipad-reconnect-resync Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
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

### Requirement: 发送窗口解析等待为事件驱动且可取消

当离开线程或执行中断需要等待 `turn/start` 请求解析时，outbox SHALL 通过状态完成事件唤醒等待者，并为每个等待者安排至多一个可取消超时任务。完成、超时与调用方取消 SHALL 竞争同一个 exactly-once 解析点；任何结果都 MUST 移除 continuation 并取消未使用的超时任务。实现 MUST NOT 在主 actor 上周期轮询状态。

#### Scenario: turn/start 完成先于超时
- **WHEN** 等待期间权威回显、请求完成或恢复流程解析了发送窗口
- **THEN** 所有等待者立即成功恢复，关联超时任务被取消且无 continuation 残留

#### Scenario: 等待超时或调用方取消
- **WHEN** 超时先到达或等待任务被取消
- **THEN** 该等待者恰好一次返回失败并从 outbox 移除，后续状态完成不得重复恢复它
