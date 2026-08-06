# ipad-approval-handling Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 权限审批（permissions/requestApproval）知情展示与协议正确响应

iPad SHALL 按当前生成协议类型化解码 `item/permissions/requestApproval`，并返回 `PermissionsRequestApprovalResponse`。权限档案 MUST 完整保留 network 与 fileSystem 的 `read`、`write`、`globScanMaxDepth`、`entries`；每个 entry 的 path 与 access mode（read/write/deny）MUST 在批准前展示，并在批准时按用户选择的 turn/session scope 原样回授。MUST NOT 因只解析旧 read/write 字段而丢失 entries，也 MUST NOT 把权限响应误编码为 command decision。

#### Scenario: entries-only 请求可知情批准
- **WHEN** 权限请求仅通过 `fileSystem.entries` 携带 read/write/deny 条目
- **THEN** 卡片逐条展示 path 与 access，批准响应完整回授 entries 与 scope

#### Scenario: 权限拒绝 fail-closed
- **WHEN** 用户拒绝 permissions request
- **THEN** iPad 回不授予任何请求权限的协议正确响应，卡片仅在确认送达后移除

#### Scenario: 旧兼容字段不丢失
- **WHEN** server 同时或仅发送 read/write 兼容字段
- **THEN** iPad 仍能展示并回授其范围，但 entries 是首选当前结构

### Requirement: 文件改动审批关联真实 item 展示

iPad SHALL 按当前 `FileChangeRequestApprovalParams` 解码 threadId、turnId、itemId、startedAtMs、reason 与 grantRoot。由于请求本身不含 file/diff，审批 UI MUST 使用 itemId 关联当前会话的 file-change item 并展示实际文件与 diff；MUST NOT 读取协议不存在的 `file` / `diff` 字段后生成空白可批准卡。

#### Scenario: 文件审批展示实际变更
- **WHEN** file approval 的 itemId 可关联到当前 ConversationState 中的 file-change item
- **THEN** 卡片展示 reason/grantRoot 和关联 item 的文件、diff，用户据此决定

#### Scenario: 无法关联时不可盲目批准
- **WHEN** file approval 的 itemId 在当前会话中找不到对应变更
- **THEN** 卡片显示协议/状态错误且禁用批准，提供刷新或拒绝路径
