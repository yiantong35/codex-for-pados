## ADDED Requirements

### Requirement: 经 SSH 隧道连接 app-server
iPad 客户端 SHALL 通过 SSH 隧道（direct-tcpip 端口转发）连接 Mac 上仅绑 loopback 的 `codex app-server`，并在转发端口上建立 WebSocket，承载 JSON-RPC 2.0。

#### Scenario: 建立隧道并完成握手
- **WHEN** 用户在 iPad 输入有效的 Mac 主机/端口/SSH 凭证并发起连接
- **THEN** 客户端建立 SSH 连接并将本地端口转发到 Mac `127.0.0.1:<app-server 端口>`
- **AND** 在转发端口上打开 WebSocket 并发送 `initialize` 请求
- **AND** 收到 `initialize` 响应后发送 `initialized` 通知，连接进入 ready 状态

#### Scenario: SSH 鉴权失败
- **WHEN** SSH 凭证无效
- **THEN** 客户端不建立连接，并向用户显示明确的鉴权失败错误，而非泛化错误

#### Scenario: app-server 不可达
- **WHEN** SSH 连接成功但转发端口上无 app-server 响应
- **THEN** 客户端报告 app-server 不可达，提示用户检查 Mac 端启动脚本

### Requirement: 凭证安全存储
iPad 客户端 SHALL 将 SSH 凭证存储在 iOS Keychain，不以明文持久化。

#### Scenario: 凭证存入 Keychain
- **WHEN** 用户保存 SSH 连接配置
- **THEN** 私钥/密码写入 iOS Keychain
- **AND** 不出现在普通可读的偏好设置或日志中

### Requirement: 断线重连与状态恢复
iPad 客户端 SHALL 在连接中断后自动重连，并依赖服务端持久态（`thread/resume`）恢复，而非内存态。

#### Scenario: 连接中断后自动重连
- **WHEN** SSH/WebSocket 连接因网络或后台回收而中断
- **THEN** 客户端以退避策略重建隧道与 WebSocket 并重新 `initialize`
- **AND** 对当前活动线程发起 `thread/resume` 恢复会话

#### Scenario: 重连期间的用户可见状态
- **WHEN** 客户端处于重连中
- **THEN** UI 显示明确的"重连中"状态，而非静默卡死
