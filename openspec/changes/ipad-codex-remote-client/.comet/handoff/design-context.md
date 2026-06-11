# Comet Design Handoff

- Change: ipad-codex-remote-client
- Phase: design
- Mode: compact
- Context hash: a89b0cffff4e035c779c0fbd984754a317f3d22d879a8d7838969a77a2d8cf40

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/ipad-codex-remote-client/proposal.md

- Source: openspec/changes/ipad-codex-remote-client/proposal.md
- Lines: 1-35
- SHA256: 0b17da0e3844f1c8656276f289bf185ddc1150236eaba7d139da52a74e496046

```md
## Why

用户在 Mac 上通过本地 Codex 桌面 app / IDE 扩展使用 OpenAI Codex，但离开电脑（在沙发、会议、外出于同一 WiFi 下）时无法查看进度、继续对话或对 Codex 的危险操作做审批。OpenAI 已把驱动其官方富客户端的连接层 `codex app-server`（JSON-RPC 2.0）开源，提供了完整的 Codex 控制面，使第三方客户端无需逆向即可接入。本变更要做一个 iPadOS 原生 app，作为 Codex 的远程 GUI 客户端。

## What Changes

- 新增一个 iPadOS 原生 SwiftUI 应用，通过 **SSH 隧道**连接运行在 Mac 上的 `codex app-server`（WebSocket 上的 JSON-RPC 2.0）。
- iPad 端**不做任何 OpenAI 鉴权**：app-server 在 Mac 上复用 `~/.codex` 现有凭证（当前环境为 API Key）。
- 支持发送指令、流式接收并渲染 Codex 输出（`turn/*`、`item/*` 事件）。
- 支持**审批流**：Codex 请求执行命令 / 修改文件时，在 iPad 上批准或拒绝（app-server server→client 反向请求）。
- 支持列出并恢复 Mac 上**已有的对话线程**（`thread/list` / `thread/resume`），包括本地 Codex 桌面 app 创建的会话（共享 `~/.codex/sessions/`）。
- 新增 Mac 端**一键启动脚本**：启动 app-server（仅绑 `127.0.0.1`）并打印连接所需信息。
- MVP 范围限定：局域网（同 WiFi，SSH 同网段）、单用户、开发者签名侧载，不上架 App Store、不做公网穿透。

## Capabilities

### New Capabilities

- `mac-launcher`: Mac 端一键启动脚本，拉起仅绑 loopback 的 `codex app-server` 并输出连接信息（IP、端口、SSH 提示）。
- `remote-connection`: iPad 端连接层——SSH 隧道（端口转发到 Mac loopback）+ WebSocket 传输 + JSON-RPC 2.0 编解码 + 连接生命周期（建立、握手、断线重连、错误反馈）。
- `conversation-streaming`: 发送 prompt、`turn/start`，流式接收并渲染 `turn/*` / `item/*` 事件的对话界面。
- `session-management`: 列出并恢复 Mac 上已有对话线程（`thread/list` / `thread/resume`），含桌面 app 创建的本地会话。
- `approval-flow`: 处理 app-server 发起的审批请求（命令执行、文件修改），在 iPad 上批准/拒绝并回传决定。

### Modified Capabilities

（无——全新项目，`openspec/specs/` 当前为空。）

## Impact

- **新代码**：iPadOS SwiftUI app（Xcode 工程）、Mac 端启动脚本。
- **新依赖**：iPad 端引入 SSH 库（候选 Citadel，基于 Apple swift-nio-ssh）；JSON-RPC / WebSocket 走系统 `URLSessionWebSocketTask`。
- **外部依赖**：`codex` CLI / app-server（当前 Mac 环境 codex-cli 0.133.0）。WebSocket 传输官方标注"实验性"，需 pin Codex 版本并从 `codex app-server generate-json-schema` 生成协议类型。
- **系统/平台**：iOS 本地网络权限（Info.plist）、后台 socket 保活限制；Mac 需开启"远程登录"(sshd)。
- **不影响**：Codex 引擎本体、云端 Codex、Mac 现有 `~/.codex` 数据（只读连接，不修改存储结构）。
```

## openspec/changes/ipad-codex-remote-client/design.md

- Source: openspec/changes/ipad-codex-remote-client/design.md
- Lines: 1-70
- SHA256: d1cef8e1ab5a9f9772b04ce82ceb083df4b50c35558e202f4ce953e9264c3b0a

```md
## Context

Codex 的官方富客户端（VS Code 扩展、桌面 app）都架在开源的 `codex app-server` 之上——它是一个 JSON-RPC 2.0 接口，暴露 Codex 的完整控制面（线程、回合、流式事件、审批、模型/技能发现等）。因此 iPad 客户端无需逆向任何专有 GUI，直接讲 JSON-RPC 即可获得与官方客户端等价的能力。

当前用户环境（已实测）：
- Mac 安装 `codex-cli 0.133.0`，`~/.codex/` 已有 22 个本地会话（来源 `vscode` / `subagent`），并存在 `app-server-daemon` / `app-server-control` 目录，说明 app-server 基础设施已在用。
- 鉴权为 `OPENAI_API_KEY`（存于 `~/.codex/auth.json`）。
- 用户日常使用**本地 Codex 桌面 app（Local 模式）**，其会话写入同一 `~/.codex/sessions/`，故 iPad 经本地 app-server 可 `thread/resume` 这些会话。

本设计为高层架构决策（open 阶段产物）。详细技术 RFC、协议 schema 细节、审批时序图将在 design 阶段（Superpowers Design Doc）展开。

## Goals / Non-Goals

**Goals:**
- iPad 经 SSH 隧道安全连接 Mac 上仅绑 loopback 的 `codex app-server`，零 LAN 暴露面。
- 完整远程控制：发指令 → 流式查看 → 审批命令/文件修改。
- 恢复 Mac 上已有对话线程（含桌面 app 会话）。
- iPad 端零 OpenAI 鉴权，复用 Mac `~/.codex` 凭证。
- Mac 端一键启动脚本降低使用门槛。

**Non-Goals:**
- 不上架 App Store（开发者签名侧载自用）。
- 不做公网/中继穿透（LAN 起步，SSH 同网段）。
- 不在 iPad 上做 OpenAI 登录。
- 不接入云端 Codex（chatgpt.com/codex 任务存于云端，本地 app-server 不可见）。
- 不修改/重实现 Codex 引擎。
- 不做多用户、协作。

## Decisions

### 决策 1：连接层用 SSH 隧道，而非明文 ws + token
- **选择**：iPad 用 SSH 库建立到 Mac 的隧道（direct-tcpip 端口转发），app-server 仅绑 `127.0.0.1:<port>`，WebSocket 跑在转发端口上。
- **理由**：Codex 能改代码、跑命令，裸暴露在 LAN 风险高。SSH 提供加密 + 密钥/密码鉴权，且 app-server 完全不暴露给网络，比 `--ws-auth capability-token`（仍明文暴露在 LAN）更安全。隧道透明转发，所有 JSON-RPC 方法功能不打折。
- **备选**：① 明文 ws + capability token（最快但暴露面大，作为后续可选）；② 两种都支持（设计量最大，MVP 不做）。

### 决策 2：iPad 端技术栈 SwiftUI + URLSessionWebSocketTask + Citadel
- **选择**：UI 用 SwiftUI；WebSocket 用系统 `URLSessionWebSocketTask`；SSH 隧道用 Citadel（基于 Apple 官方 swift-nio-ssh，支持 TCP 端口转发，SPM 集成）。
- **理由**：全部 Swift 原生 / 一方依赖，最小化第三方风险；Citadel 是 iOS 上成熟的 SSH 端口转发方案。
- **备选**：直接用 swift-nio-ssh（更底层，需自己实现 direct-tcpip 通道）；NMSSH（Obj-C，较老）。

### 决策 3：协议类型从 app-server 生成，并 pin Codex 版本
- **选择**：用 `codex app-server generate-json-schema` 生成协议 schema，据此在 Swift 侧建模 JSON-RPC 请求/事件类型；在文档中锁定目标 Codex 版本（当前 0.133.0）。
- **理由**：WebSocket 传输官方标注"实验性、不保证稳定"，协议可能随版本演进。生成 + pin 可避免手写类型漂移。

### 决策 4：iPad 端零鉴权，凭证留在 Mac
- **选择**：iPad 不接触 OpenAI 凭证；app-server 在 Mac 上用 `~/.codex` 现有 auth（当前 API Key）。iPad 的"鉴权"仅指 SSH 登录 Mac。
- **理由**：最简单也最安全的信任模型——敏感凭证不离开 Mac。

### 决策 5：会话恢复经 `thread/list` + `thread/resume`
- **选择**：iPad 拉取 `thread/list`（默认含 cli/vscode/atlas 等交互来源）展示历史，选中后 `thread/resume` by `threadId`。
- **理由**：rollout store 按 UUID 寻址、不区分创建客户端，桌面 app 会话天然可恢复，直接满足"连到 codex app 内 session"的核心诉求。

## Risks / Trade-offs

- **WebSocket 传输实验性，协议可能变** → pin Codex 版本；从 generate-json-schema 生成类型；隔离协议层便于升级。
- **iOS 后台 socket 限制导致隧道/连接被系统回收** → 设计断线重连 + 会话状态恢复（依赖 thread/resume 而非内存态）；前台优先，后台保活作为后续优化。
- **Citadel 在 iPadOS 上端口转发的稳定性未知** → design 阶段先做技术验证 spike（最小 SSH 转发 demo 跑通 app-server 握手）后再铺开。
- **审批时序复杂（server→client 反向请求 + 超时）** → design 阶段画清审批状态机；MVP 明确超时/断连时的默认行为（倾向拒绝/挂起，不自动批准）。
- **桌面 app 内部进程模型未公开**（是否内嵌 app-server）→ 不依赖其进程模型，只依赖共享的 `~/.codex/sessions/` on-disk store。

## Migration Plan

全新项目，无存量迁移。回滚 = 不部署该 app；对 Mac 仅新增一个启动脚本与开启 sshd，不改动 `~/.codex` 数据。

## Open Questions

- Citadel 端口转发在真实 iPadOS 设备上的可靠性与后台行为（design 阶段 spike 验证）。
- 审批超时 / 连接中断时的默认策略（拒绝 vs 挂起待恢复）——design 阶段定。
- `thread/list` 默认来源过滤是否需要扩展 `sourceKinds` 以覆盖桌面 app 的 `atlas` 来源（需实测确认默认集是否已含）。
- MVP 是否需要多项目（多 cwd）切换，还是先单项目。
```

## openspec/changes/ipad-codex-remote-client/tasks.md

- Source: openspec/changes/ipad-codex-remote-client/tasks.md
- Lines: 1-39
- SHA256: 27ec3573d818785a2445efe02406b16e83500cf58343e04307ff0c9a060a7b69

```md
## 1. Mac 端启动器（mac-launcher）
- [ ] 1.1 编写一键启动脚本：拉起 `codex app-server --listen ws://127.0.0.1:<port>`（仅绑 loopback）
- [ ] 1.2 脚本输出连接信息：Mac LAN IP、端口、SSH 用户名/提示，并校验 sshd（远程登录）是否开启
- [ ] 1.3 脚本健壮性：端口占用检测、Codex 版本校验（pin 目标版本）、优雅退出/清理

## 2. 协议与技术验证（spike）
- [ ] 2.1 用 `codex app-server generate-json-schema` 生成协议 schema，纳入仓库
- [ ] 2.2 spike：最小 SSH 端口转发 demo（Citadel）跑通到 Mac loopback 的 TCP 转发
- [ ] 2.3 spike：经隧道完成 app-server `initialize` → `initialized` 握手，验证连通性

## 3. iPad 连接层（remote-connection）
- [ ] 3.1 Xcode 工程脚手架（SwiftUI App、SPM 依赖 Citadel）、Info.plist 本地网络权限
- [ ] 3.2 连接配置界面：Mac 主机/端口/SSH 凭证（密钥/密码）的输入与安全存储（Keychain）
- [ ] 3.3 SSH 隧道层：建立连接 + direct-tcpip 端口转发到 app-server
- [ ] 3.4 WebSocket + JSON-RPC 2.0 编解码层（请求/响应/通知，基于生成的 schema 类型）
- [ ] 3.5 连接生命周期：握手、断线检测、自动重连、错误反馈 UI

## 4. 会话管理（session-management）
- [ ] 4.1 调用 `thread/list` 拉取并展示历史会话（确认默认 sourceKinds 覆盖桌面 app `atlas` 来源）
- [ ] 4.2 选中会话 `thread/resume` by threadId，加载并渲染历史
- [ ] 4.3 新建会话 `thread/start`

## 5. 对话与流式输出（conversation-streaming）
- [ ] 5.1 发送 prompt：`turn/start`
- [ ] 5.2 订阅并渲染 `turn/*` / `item/*` 流式事件（增量文本、工具调用、状态）
- [ ] 5.3 turn 控制：`turn/interrupt`（中断）基础支持
- [ ] 5.4 对话 UI：消息流、Markdown/代码块渲染、滚动与加载态

## 6. 审批流（approval-flow）
- [ ] 6.1 处理 server→client 审批请求（命令执行、文件修改）的接收与解析
- [ ] 6.2 审批 UI 卡片：展示请求内容（命令/diff），批准/拒绝按钮
- [ ] 6.3 回传审批决定，渲染执行结果
- [ ] 6.4 边界处理：审批超时 / 连接中断时的默认策略（不自动批准）

## 7. 联调与验收
- [ ] 7.1 端到端：iPad 连 Mac → 发 prompt → 流式看到回复（核心成功场景）
- [ ] 7.2 端到端：恢复一个桌面 app 创建的已有会话并继续对话
- [ ] 7.3 端到端：触发命令/文件修改 → iPad 审批闭环（批准 + 拒绝两条路径）
- [ ] 7.4 异常：网络/SSH 断开的优雅提示与重连；SSH 鉴权失败的明确报错
```

## openspec/changes/ipad-codex-remote-client/specs/approval-flow/spec.md

- Source: openspec/changes/ipad-codex-remote-client/specs/approval-flow/spec.md
- Lines: 1-44
- SHA256: 43f1de28b8c6cbbd64e62cc4eba6df5a9efe08cd22f685a0474d53d93636c2d2

```md
## ADDED Requirements

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
```

## openspec/changes/ipad-codex-remote-client/specs/conversation-streaming/spec.md

- Source: openspec/changes/ipad-codex-remote-client/specs/conversation-streaming/spec.md
- Lines: 1-49
- SHA256: 62d60fd7bef1da67b6574c904b591af616bda642e4a58178e9fafa2f2e56299e

```md
## ADDED Requirements

### Requirement: 发送指令并流式渲染回复
iPad 客户端 SHALL 通过 `turn/start` 发送用户输入，并流式订阅并渲染 `turn/*` 与 `item/*` 事件。

#### Scenario: 发送 prompt 并看到流式正文
- **WHEN** 用户在 composer 输入文本并发送
- **THEN** 客户端发送 `turn/start`（携带 `input`）
- **AND** 随 `item/agentMessage/delta` 事件增量渲染 agent 正文
- **AND** 收到 `turn/completed` 后标记该回合结束

#### Scenario: 渲染命令执行输出
- **WHEN** Codex 执行命令并流式产出输出
- **THEN** 客户端随 `item/commandExecution/outputDelta` 增量渲染命令输出面板

#### Scenario: 渲染文件改动 diff
- **WHEN** Codex 产生文件改动
- **THEN** 客户端展示文件编辑卡（文件名 + 增删行数）
- **AND** 展开后随 `turn/diff/updated` / `item/fileChange/patchUpdated` 渲染逐行红绿 diff

### Requirement: 中途控制（转向、排队、中断）
iPad 客户端 SHALL 支持在 turn 进行中转向（steer）、排队后续输入、以及中断。

#### Scenario: 转向活动 turn
- **WHEN** 某 turn 正在进行且用户提交转向输入
- **THEN** 客户端以 `turn/steer`（携带 `expectedTurnId`）注入输入

#### Scenario: 排队后续输入
- **WHEN** 某 turn 正在进行且用户提交新输入并选择排队
- **THEN** 客户端缓冲该输入，待 `turn/completed` 后以 `turn/start` 发送

#### Scenario: 转向不可 steer 的 turn
- **WHEN** 当前 turn 为 `review` 或 `compact` 类型（不可转向）
- **THEN** 客户端不发 `turn/steer`，并提示该回合不支持转向

#### Scenario: 中断进行中的 turn
- **WHEN** 用户对进行中的 turn 触发中断
- **THEN** 客户端发送 `turn/interrupt`

### Requirement: composer 输入能力
composer SHALL 支持文本、图片附件，以及模型/推理选择。

#### Scenario: 图片附件
- **WHEN** 用户在 composer 添加图片并发送
- **THEN** 图片作为 `UserInput` 的一部分随 `turn/start` 发送

#### Scenario: 调整模型与推理强度
- **WHEN** 用户在 composer 选择不同模型或推理强度
- **THEN** 该选择作为 `turn/start` 的 `model` / `reasoningEffort` 覆盖发送
```

## openspec/changes/ipad-codex-remote-client/specs/mac-launcher/spec.md

- Source: openspec/changes/ipad-codex-remote-client/specs/mac-launcher/spec.md
- Lines: 1-21
- SHA256: e489164703fdf67eb674b18d33f3ea5109dc9e06ca79b6df624ce6619404079f

```md
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
```

## openspec/changes/ipad-codex-remote-client/specs/remote-connection/spec.md

- Source: openspec/changes/ipad-codex-remote-client/specs/remote-connection/spec.md
- Lines: 1-38
- SHA256: 67b49c71abff18a414cf1161c24df2e266b3c5847d16dfd94a4d1d8819eec69f

```md
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
```

## openspec/changes/ipad-codex-remote-client/specs/session-management/spec.md

- Source: openspec/changes/ipad-codex-remote-client/specs/session-management/spec.md
- Lines: 1-32
- SHA256: 488eb367a22f7eff01cd2f1e4cf91359fce0a69c3356a2e21a1faace08938c91

```md
## ADDED Requirements

### Requirement: 按项目列出并恢复已有对话
iPad 客户端 SHALL 经 `thread/list` 拉取 Mac 上的对话线程，按 `cwd` 分组为「项目」展示于左栏，并支持 `thread/resume` 恢复，包括本地 Codex 桌面 app 创建的会话。

#### Scenario: 左栏按项目分组展示对话
- **WHEN** 连接进入 ready 状态
- **THEN** 客户端调用 `thread/list` 并按线程 `cwd` 将对话分组为项目
- **AND** 左栏展示「项目 → 对话」树，每个对话条目显示标题与相对时间

#### Scenario: 恢复桌面 app 创建的会话
- **WHEN** 用户在左栏选中一个由本地 Codex 桌面 app 创建的对话
- **THEN** 客户端以 `thread/resume`（by `threadId`）加载并渲染该会话历史

#### Scenario: 桌面来源会话可见
- **WHEN** `thread/list` 的默认 `sourceKinds` 未包含桌面 app 来源
- **THEN** 客户端显式传入覆盖桌面 app 来源的 `sourceKinds`，确保桌面会话出现在列表

### Requirement: 新建对话
iPad 客户端 SHALL 支持新建对话线程。

#### Scenario: 新建对话
- **WHEN** 用户发起新对话
- **THEN** 客户端以 `thread/start` 创建新线程并进入对话详情

### Requirement: 待批准状态徒标
左栏对话条目 SHALL 在该对话存在未决审批请求时显示「等待批准」状态徒标。

#### Scenario: 显示等待批准徒标
- **WHEN** 某对话收到尚未处理的审批请求
- **THEN** 该对话在左栏的条目显示「等待批准」徒标
- **AND** 审批被处理或被他端解决后徒标消失
```

