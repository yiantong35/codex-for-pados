# ipad-multi-connection Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 自动连接尊重用户主动断开意图

每个 Session SHALL 将用户连接意图与瞬时 ConnectionPhase 分开保存。用户显式 Disconnect 后，tab 切换、app 回前台、冷启动 bootstrap 和通用 shouldAutoConnect 判定 MUST NOT 自动连接该 Session；只有用户显式 Connect、重新配对或新增机器时才恢复自动连接意图。网络异常导致的 disconnected/failed 仍可按既有策略自动恢复。

#### Scenario: 主动断开后切 tab 不重连
- **WHEN** 用户断开机器 A，切到机器 B 后再切回 A
- **THEN** A 保持断开并显示可手动连接入口，不自动创建 transport

#### Scenario: 主动断开后回前台不重连
- **WHEN** 用户主动断开当前 Session 后使 app 后台再回前台
- **THEN** SessionsManager 不自动调用 connect

#### Scenario: 显式连接恢复自动意图
- **WHEN** 用户在主动断开状态点击 Connect
- **THEN** Session 恢复自动连接意图并开始连接，后续异常掉线仍走既有重连策略
