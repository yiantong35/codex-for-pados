## ADDED Requirements

### Requirement: 终端进程退出状态权威收敛并可重启

TerminalSession SHALL 跟踪每次 `command/exec` 的 processId 与 generation，并消费其最终 response。shell 自然退出、手动 terminate、连接断开或 cwd 切换后，当前进程的 `running` 和 processId MUST 收敛为非运行状态，使同 cwd 再次打开可启动新 shell。旧 generation 的迟到 response MUST NOT 清理或覆盖新进程状态。

#### Scenario: shell 自然退出后可重启
- **WHEN** 用户输入 `exit`，`command/exec` 返回最终 exitCode
- **THEN** TerminalSession 清 running/processId、呈现退出状态，再次打开终端会生成新 processId

#### Scenario: terminate 后同 cwd 可重启
- **WHEN** 用户终止当前 shell 后再次打开同一 cwd 终端
- **THEN** startIfNeeded 不被旧 processId 阻塞，启动新 shell

#### Scenario: 旧响应不影响新进程
- **WHEN** 旧 shell 的最终 response 在新 shell 已启动后迟到
- **THEN** generation 校验丢弃旧 response，新 shell 保持 running
