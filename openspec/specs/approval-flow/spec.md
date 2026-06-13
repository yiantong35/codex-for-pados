# approval-flow Specification

## Purpose
TBD - created by archiving change ipad-codex-remote-client. Update Purpose after archive.
## Requirements
### Requirement: 接收并展示审批请求
iPad 客户端 SHALL 注册 server→client 审批请求处理器，覆盖 v2 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、`item/permissions/requestApproval`，并兼容 legacy `execCommandApproval`、`applyPatchApproval`。

#### Scenario: 命令执行审批
- **WHEN** app-server 发来命令执行审批请求
- **THEN** 客户端在对话中展示审批卡片，含待执行命令明细

#### Scenario: 文件改动审批
- **WHEN** app-server 发来文件改动审批请求
- **THEN** 客户端展示审批卡片，含改动文件与 diff 摘要

#### Scenario: 兼容 legacy 审批
- **WHEN** app-server 发来 legacy `execCommandApproval` 或 `applyPatchApproval` 请求
- **THEN** 客户端同样识别并展示审批卡片，不丢弃请求

### Requirement: 多选项审批响应
审批卡片 SHALL 提供多选项响应，包括批准、批准且本会话对该命令前缀不再询问、以及拒绝，并以对应决定回传 JSON-RPC 响应。

#### Scenario: 批准
- **WHEN** 用户在审批卡片选择"是"
- **THEN** 客户端以批准的 `ReviewDecision` 回传该请求的 JSON-RPC 响应
- **AND** 后续渲染该操作的执行结果

#### Scenario: 批准并本会话放行前缀
- **WHEN** 用户选择"是，且此前缀命令本会话不再询问"
- **THEN** 客户端回传批准决定，并携带会话级前缀放行（`ExecPolicyAmendment`）

#### Scenario: 拒绝
- **WHEN** 用户选择"否"
- **THEN** 客户端回传拒绝决定，Codex 收到拒绝

### Requirement: 审批的并发与边界处理
客户端 SHALL 正确处理审批被他端解决、以及超时/断线未决的情形，且任何情况下不自动批准。

#### Scenario: 审批被他端解决
- **WHEN** 同一审批请求被其他客户端（如桌面 app）先行处理，客户端收到 `serverRequest/resolved`
- **THEN** 客户端移除该审批卡片，不再要求用户处理

#### Scenario: 超时或断线未决不自动批准
- **WHEN** 审批请求在用户决定前发生超时或连接中断
- **THEN** 客户端不自动批准
- **AND** 将该审批标记为待恢复，重连后若服务端重发则重新展示

