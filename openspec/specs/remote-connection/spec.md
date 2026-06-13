# remote-connection Specification

## Purpose
TBD - created by archiving change ipad-codex-remote-client. Update Purpose after archive.
## Requirements
### Requirement: 经 SSH + codex proxy 连接受管 app-server daemon
iPad 客户端 SHALL 通过 SSH exec 远端 `codex app-server proxy`，在 SSH 通道的 stdio 上承载 JSON-RPC 2.0（换行分隔），连接 Mac 上由 `codex app-server daemon` 管理的 app-server（经 control socket）。

#### Scenario: 建立连接并完成握手
- **WHEN** 用户在 iPad 输入有效的 Mac 主机/端口/SSH 凭证并发起连接
- **THEN** 客户端建立 SSH 连接并经 exec 通道运行远端 `codex app-server proxy`
- **AND** 在该通道 stdio 上发送 `initialize` 请求
- **AND** 收到 `initialize` 响应后发送 `initialized` 通知，连接进入 ready 状态

#### Scenario: SSH 鉴权失败
- **WHEN** SSH 凭证无效
- **THEN** 客户端不建立连接，并向用户显示明确的鉴权失败错误，而非泛化错误

#### Scenario: 远程控制未就绪
- **WHEN** SSH 连接成功但远端 `codex app-server proxy` 不可用或受管 daemon 未启用远程控制
- **THEN** 客户端报告远程控制不可达，提示用户在 Mac 端运行 daemon bootstrap/enable-remote-control

### Requirement: 启动自动重连上次连接
iPad 客户端 SHALL 在启动时，若存在已保存的上次连接信息（主机/端口/用户）且连接密钥已生成，自动发起连接一次，使用户无需每次手动点击连接。

#### Scenario: 启动自动连接
- **WHEN** app 启动且存在已保存的主机/用户与已生成的连接密钥，且当前为断开状态
- **THEN** 客户端自动发起一次连接，无需用户手动点击「连接」

#### Scenario: 首次或无保存信息不自动连接
- **WHEN** app 启动但无已保存的主机/用户或尚未生成密钥
- **THEN** 客户端停留在连接配置界面，等待用户输入并手动连接

#### Scenario: 自动连接失败不循环重试
- **WHEN** 启动自动连接失败
- **THEN** 客户端停留在连接配置界面并显示错误，不自动循环重试（由用户手动重连）

### Requirement: 凭证安全存储
iPad 客户端 SHALL 将 SSH 凭证存储在 iOS Keychain，不以明文持久化。

#### Scenario: 凭证存入 Keychain
- **WHEN** 用户保存 SSH 连接配置
- **THEN** 私钥/密码写入 iOS Keychain
- **AND** 不出现在普通可读的偏好设置或日志中

### Requirement: 断线重连与状态恢复
iPad 客户端 SHALL 在连接中断后自动重连，并依赖服务端持久态（`thread/resume`）恢复，而非内存态。

#### Scenario: 连接中断后自动重连
- **WHEN** SSH 连接或 proxy 通道因网络或后台回收而中断
- **THEN** 客户端以退避策略重建 SSH 连接并重新 exec `codex app-server proxy` 后重新 `initialize`
- **AND** 对当前活动线程发起 `thread/resume` 恢复会话

#### Scenario: 重连期间的用户可见状态
- **WHEN** 客户端处于重连中
- **THEN** UI 显示明确的"重连中"状态，而非静默卡死

#### Scenario: iPad 断开不影响 Mac 侧 daemon
- **WHEN** iPad 客户端断开连接
- **THEN** Mac 上的受管 app-server daemon 与 desktop app 不受影响，继续正常运行

