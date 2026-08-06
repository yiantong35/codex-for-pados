# ipad-interactive-server-requests Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 所有 server-initiated request 均有唯一终态响应

iPad JSON-RPC 层 SHALL 对仓库生成 `ServerRequest` 联合类型中的每个 method 建立穷尽路由。每个 request id MUST 由唯一 owner 处理并最终回成功 result 或 JSON-RPC error；客户端未实现的方法 MUST 立即回明确的 method-not-supported/error，MUST NOT 被静默丢弃并使 server turn 无限等待。

#### Scenario: 未支持方法显式失败
- **WHEN** app-server 发出 iPad 未实现的 dynamic tool、auth refresh 或 attestation 请求
- **THEN** iPad 对同一 request id 回明确 JSON-RPC error，turn 不因无响应永久挂起

#### Scenario: request 只响应一次
- **WHEN** 同一 request 同时可被广播观察者看见
- **THEN** 只有注册 owner 可发送终态响应，任何 observer 不得重复 respond

### Requirement: request_user_input 在 iPad 可完成

iPad SHALL 渲染 `item/tool/requestUserInput` 的全部 questions，支持服务端 options 与 free-form 输入、多问题提交、取消和 `autoResolutionMs`。提交结果 MUST 对齐生成的 `ToolRequestUserInputResponse`；断线或视图切换 MUST NOT 自动接受默认值。

#### Scenario: 多问题输入并提交
- **WHEN** server request 同时包含选项题与自由输入题
- **THEN** iPad 展示所有问题，用户完成后一次性回协议正确 response，agent turn 继续

#### Scenario: 自动解决超时
- **WHEN** 请求含 `autoResolutionMs` 且用户在时限内未操作
- **THEN** iPad 按协议规定的自动解决语义响应或取消，并移除该请求，绝不无限等待

### Requirement: MCP elicitation 在 iPad 可完成或明确拒绝

iPad SHALL 支持当前生成协议的 MCP URL elicitation 与表单 elicitation。表单字段 SHALL 按 string/number/boolean/enum/array/object schema 使用相应控件并在本地验证；未知或不可表示 schema MUST 显式回 error，MUST NOT 猜测、截断或静默等待。

#### Scenario: 表单 elicitation 提交
- **WHEN** MCP server 请求一组受支持 schema 字段
- **THEN** iPad 渲染表单、校验输入并回 `McpServerElicitationRequestResponse`

#### Scenario: 未知 schema fail-closed
- **WHEN** elicitation 包含客户端不支持的 schema 组合
- **THEN** iPad 显示不能完成的状态并回明确 error，不生成宽松或错误字段值
