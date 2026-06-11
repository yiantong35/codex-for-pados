## ADDED Requirements

### Requirement: Mac 端一键启用 SSH 远程控制 daemon
脚本 SHALL 在 Mac 上经 `codex app-server daemon` 拉起/确保受管 app-server daemon 并启用远程控制，使 iPad 可经 SSH + `codex app-server proxy` 接入；脚本不自起独立 `--listen ws://` 进程，不与 desktop app 的 app-server 冲突。

#### Scenario: 正常启用远程控制并输出连接信息
- **WHEN** 用户在 Mac 上运行启动脚本
- **THEN** 脚本经 `codex app-server daemon bootstrap --remote-control`（或对运行中 daemon 用 `enable-remote-control`）确保受管 daemon 已启用远程控制
- **AND** 打印 Mac 的 LAN IP、SSH 登录用户名提示、以及 iPad 经 SSH exec `codex app-server proxy` 的接入说明

#### Scenario: sshd 未开启时提示
- **WHEN** 运行脚本且 Mac 的"远程登录"(sshd) 未开启
- **THEN** 脚本检测到 sshd 未启用并明确提示用户开启，而非静默继续

#### Scenario: daemon 已运行
- **WHEN** 受管 daemon 已在运行
- **THEN** 脚本不重复创建实例，仅确保远程控制已启用，并报告当前 daemon 状态/版本

#### Scenario: codex 版本不符合 pin
- **WHEN** 本机 codex 版本与设计 pin 的版本不一致
- **THEN** 脚本输出版本不匹配警告，提示协议可能不兼容
