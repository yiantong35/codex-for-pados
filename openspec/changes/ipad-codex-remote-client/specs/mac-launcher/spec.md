## ADDED Requirements

### Requirement: Mac 端一键启动 app-server
脚本 SHALL 在 Mac 上启动 `codex app-server`，仅绑定 `127.0.0.1`，并输出 iPad 连接所需信息。

#### Scenario: 正常启动并输出连接信息
- **WHEN** 用户在 Mac 上运行启动脚本
- **THEN** 脚本以 `--listen ws://127.0.0.1:<port>` 启动 app-server（不绑定 LAN 地址）
- **AND** 打印 Mac 的 LAN IP、监听端口、SSH 登录用户名提示

#### Scenario: sshd 未开启时提示
- **WHEN** 运行脚本且 Mac 的"远程登录"(sshd) 未开启
- **THEN** 脚本检测到 sshd 未启用并明确提示用户开启，而非静默继续

#### Scenario: 端口被占用
- **WHEN** 目标端口已被占用
- **THEN** 脚本报告端口冲突并退出，不启动重复实例

#### Scenario: codex 版本不符合 pin
- **WHEN** 本机 codex 版本与设计 pin 的版本不一致
- **THEN** 脚本输出版本不匹配警告，提示协议可能不兼容
