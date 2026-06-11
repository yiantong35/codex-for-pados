---
comet_change: ipad-codex-remote-client
role: technical-design
canonical_spec: openspec
---

# iPad Codex 远程 GUI 客户端 — 技术设计

> OpenSpec delta spec 是规范事实源（`openspec/changes/ipad-codex-remote-client/specs/`）。本文档是技术 RFC，描述 HOW；WHAT/验收场景以 delta spec 为准。

## 1. Context

OpenAI 已开源 `codex app-server`（JSON-RPC 2.0），它是 Codex 官方富客户端（VS Code 扩展、桌面 app）的统一连接层，暴露 Codex 完整控制面。第三方客户端无需逆向，直接讲 JSON-RPC 即可获得对等能力。

已基于用户 Mac 上真实的 **codex 0.133.0** 探查协议（`codex app-server generate-ts/generate-json-schema`），确认：客户端方法、服务端审批请求、流式事件齐备（见 §4）。**并实测发现 codex 内建官方 SSH 远程控制机制**：`codex app-server daemon bootstrap --remote-control`（"durable local app-server management for SSH-driven use"）+ `codex app-server proxy`（把 stdio 桥接到 control socket）。Mac 上 desktop app 已运行多个 app-server 实例与受管 daemon；采用官方 daemon+proxy 路径可与 desktop 共存、共享受管 daemon，避免自起独立 ws 进程。用户日常用**本地 Codex 桌面 app（Local 模式）**，会话写入 `~/.codex/sessions/`，iPad 经此可 `thread/resume` 这些会话。鉴权为 `OPENAI_API_KEY`，存于 `~/.codex/auth.json`。

**北极星**：完全对等桌面 app 体验。协议层面可行，差距只在各面板的 SwiftUI 重做工时。策略：架构按对等设计（协议层一次性订阅全事件、UI 面板可插拔），v1 先交核心。

## 2. Goals / Non-Goals

**Goals（v1）：**
- iPad 经 **SSH + codex 官方 proxy** 连接 Mac 上受管 app-server daemon（control socket 仅属主、零网络端口暴露）。
- 复刻桌面三栏布局的**左栏（项目→对话树）+ 中栏（对话）**。
- 完整远程控制：发指令、流式查看、**多选项审批**（命令/文件/权限）、命令输出、文件 diff。
- 恢复 Mac 上已有对话线程（含桌面 app 会话）。
- composer：图片附件、模型/推理可调、中途转向（steer）+ 排队。
- iPad 端零 OpenAI 鉴权，复用 Mac `~/.codex`。
- Mac 端一键启动脚本。

**Non-Goals：**
- 不上架 App Store（开发者签名侧载）；不做公网/中继穿透（LAN 起步）。
- 不在 iPad 做 OpenAI 登录；不接云端 Codex；不改/重实现 Codex 引擎。
- v1 不做：后台通知、右栏环境信息富态（git/进度/任务/浏览器）、realtime 语音、推理流面板、plan 面板（均列入 v2+ 对等路线）。

## 3. 架构分层

```
SwiftUI 层    NavigationSplitView（三列：侧栏｜对话｜inspector）
              横屏三列；竖屏侧栏抽屉化、inspector 收 sheet
─────────────────────────────────────────────────────────
状态层 @Observable   ConnectionStore · ProjectsStore ·
                     ConversationStore · ApprovalStore
─────────────────────────────────────────────────────────
领域/归约层   把 ServerNotification 流归约为可观察状态
              （Thread/Turn/Item/Approval 模型，由 schema 派生）
─────────────────────────────────────────────────────────
JSON-RPC 层 (actor)  请求/响应按 id 关联 · 通知 async 流 ·
                     server→client 请求(审批)处理器分发
─────────────────────────────────────────────────────────
传输层 (actor)  SSH(Citadel) exec 通道 → 远端
                `codex app-server proxy` → JSON-RPC(stdio) ↔ control socket
```

每层单一职责、接口清晰、可独立测试。传输层与 JSON-RPC 层用 `actor` 隔离并发；状态层用 `@Observable`（Observation 框架）驱动 SwiftUI。

> **传输机制（采用 codex 官方 SSH 远程控制路径）**：codex 内建为 SSH 远程控制设计的机制——`codex app-server daemon bootstrap --remote-control` 在 Mac 上拉起受管 daemon 并暴露 control socket（`~/.codex/app-server-control/app-server-control.sock`，`srw-------` 仅属主）；`codex app-server proxy` 把 stdio 字节透明桥接到该 control socket。iPad 经 SSH **exec** 远端 `codex app-server proxy`，直接在 SSH 通道的 stdio 上讲 JSON-RPC 2.0（换行分隔），**无需 WebSocket、无需 direct-tcpip 端口转发**。与 desktop **共享受管 daemon**，活动 turn/审批状态互通（`serverRequest/resolved` 正为此），并为多端共存设计。

## 4. 协议事实（codex 0.133.0，节选 MVP 相关）

**客户端→服务端方法**：`initialize` + `initialized`(notif)；`thread/list`·`resume`·`start`·`read`·`archive`·`name/set`；`turn/start`·`steer`·`interrupt`；`model/list`·`skills/list`。

**远程控制 daemon/proxy（codex 0.133.0 实测）**：`codex app-server daemon bootstrap [--remote-control]`（"durable local app-server management for SSH-driven use"）、`daemon enable-remote-control`、`daemon start/restart/stop`；`codex app-server proxy [--sock <path>]`（"Proxy stdio bytes to the running app-server control socket"）。这是官方 SSH 远程控制接入路径。

**服务端→客户端请求（审批，需注册处理器）**：v2 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、`item/permissions/requestApproval`；legacy `execCommandApproval`、`applyPatchApproval`。

**服务端通知（流式）**：`item/started`·`completed`、`item/agentMessage/delta`、`item/commandExecution/outputDelta`、`item/fileChange/patchUpdated`、`turn/started`·`completed`·`diff/updated`、`thread/started`·`status/changed`、`serverRequest/resolved`、`error`·`warning`·`guardianWarning`。

**关键参数事实**：
- `TurnStartParams`：per-turn 可覆盖 `model`/`reasoningEffort`/`approvalPolicy`(AskForApproval)/`approvalsReviewer`/`sandboxPolicy`/`cwd`/`input: UserInput[]`。
- `TurnSteerParams`：`{ threadId, input[], expectedTurnId }`，注入活动 turn；`NonSteerableTurnKind = review|compact` 不可 steer。
- 排队无服务端方法 → 客户端缓冲 + `turn/completed` 后 `turn/start`（桌面亦如此）。

## 5. Decisions

### D1：连接层用 codex 官方 SSH 远程控制（daemon + proxy）
Mac 端用 `codex app-server daemon bootstrap --remote-control` 拉起受管 daemon（暴露仅属主可读的 control socket）。iPad 用 Citadel 建 SSH 连接，经 **exec 通道**运行远端 `codex app-server proxy`，在 SSH 通道 stdio 上直接讲 JSON-RPC 2.0。app-server 不暴露任何网络端口（control socket 是本机 unix socket）；SSH 提供加密 + 密钥鉴权；与 desktop 共享受管 daemon、为多端共存设计。**备选**：自起 `codex app-server --listen ws://127.0.0.1` 独立实例 + SSH direct-tcpip 端口转发 + WebSocket（ws 传输官方标"实验性/unsupported"，且是独立进程、活动态与 desktop 隔离）——本设计不采用，仅作降级备选。

### D2：技术栈 SwiftUI + Citadel（SSH exec）+ 系统 JSON
UI 用 SwiftUI + Observation；SSH 用 Citadel（基于 Apple swift-nio-ssh），经 **exec 通道**跑远端 `codex app-server proxy`；JSON-RPC 走 SSH stdio 的换行分隔 JSON（系统 `JSONEncoder/Decoder`，不需要 WebSocket）。全 Swift/一方依赖。**备选**：direct-tcpip 端口转发 + `URLSessionWebSocketTask`（方案 B 才需要）。

### D3：协议类型从 schema 生成 + pin 版本
用 `generate-ts`/`generate-json-schema` 生成 schema 纳入仓库，据此建模 Swift `Codable` 类型；pin codex 0.133.0。协议层隔离，升级时只换生成层。**理由**：WS 传输官方标"实验性"。

### D4：iPad 零鉴权，凭证留 Mac
iPad 不接触 OpenAI 凭证；app-server 用 Mac `~/.codex`。iPad 的"鉴权"仅指 SSH 登录 Mac，密钥存 iOS Keychain。

### D5：会话恢复经 thread/list + thread/resume
左栏按 `thread/list` 返回的 `cwd` 分组为「项目」，每项目下挂对话；选中 `thread/resume` by `threadId`。rollout store 按 UUID 寻址、不分客户端，桌面 app 会话天然可恢复。

### D6：审批以 v2 为主 + legacy 兼容
注册 v2 `item/*/requestApproval` 处理器为主，保留 legacy `execCommandApproval`/`applyPatchApproval` 兼容。审批是**多选项**（见 §6），非二元。

### D7：UI 复刻三栏，v1 落左+中栏
横屏三列 `NavigationSplitView`；右 inspector v1 简态（输出/来源），富态环境信息留 v2+。

## 6. 审批流（多选项，最关键）

桌面审批不是批准/拒绝二元，而是多选项（截图实证）：① 是 ② **是，且此前缀命令本会话不再询问**（会话级策略放行）③ 否 + 反馈。

```
ServerRequest(item/commandExecution/requestApproval ...)
   → JSON-RPC 层识别为 server→client 请求
   → ApprovalStore 入队 → 中栏渲染审批卡片（命令/diff/权限明细）
   → 用户选择多选项之一
   → 以对应 ReviewDecision(+ 可选 ExecPolicyAmendment 前缀放行) 回 JSON-RPC 响应
并发：订阅 serverRequest/resolved → 被他端（如桌面）先处理则移除卡片
边界：超时/断线未决 → 绝不自动批准；标记待恢复，重连后服务端可能重发
```

审批策略亦可经 `turn/start` 的 `approvalPolicy`/`approvalsReviewer`/`sandboxPolicy` per-turn 调整。

## 7. 连接生命周期（状态机）

```
disconnected → sshConnecting → execProxy(codex app-server proxy)
  → initializing(initialize→initialized) → ready
ready --断线--> reconnecting --(重建 SSH + 重 exec proxy)--> initializing
  → thread/resume 当前线程（依赖服务端持久态，不靠内存）
```
指数退避重连；iOS 后台 socket 被回收时，恢复依赖 `thread/resume` 而非内存态；前台优先，后台保活列 v2+。受管 daemon 由 Mac 侧维持，iPad 断开不影响 daemon 与 desktop。

## 8. Mac 端启动器

Shell 脚本（一次性 + 日常便捷）：① `codex app-server daemon bootstrap --remote-control`（或 daemon 已运行则 `daemon enable-remote-control`）拉起受管 daemon 并开启远程控制 ② 校验 sshd（`systemsetup -getremotelogin`）③ 校验 codex 版本符合 pin ④ 打印 Mac LAN IP / SSH 用户 / 提示 iPad 经 SSH exec `codex app-server proxy` 接入 ⑤ `daemon version` 自检、`daemon stop` 清理选项。**不**自起 `--listen ws://` 进程，不与 desktop 的 app-server 冲突。

## 9. 模块边界（可独立理解/测试）

| 单元 | 做什么 | 依赖 |
|---|---|---|
| `SSHClient` | 建 SSH 连接 + exec 远端命令 | Citadel |
| `ProxyChannel` | exec `codex app-server proxy`，暴露 stdio 双向字节流 | SSHClient |
| `JSONRPCClient` (actor) | 换行分隔 JSON 帧、id 关联、通知流、server 请求分发 | ProxyChannel |
| `CodexProtocol` | schema 派生的 Codable 类型 | 生成层 |
| `ThreadReducer` | notification → 会话状态 | CodexProtocol |
| `*Store` | 可观察应用状态 | reducer |
| SwiftUI Views | 三栏渲染 | stores |

## 10. 测试策略

- **协议层/归约层（可脱真机）**：录制真实 app-server 帧为 fixture，mock 传输层重放，单元测试 JSON-RPC 编解码、审批映射、`ThreadReducer` 对合成事件序列的归约。
- **SSH exec proxy 通道**：技术验证 spike（exec `codex app-server proxy` + `initialize` 握手）+ 手动 E2E，无法纯单元测试。
- **验收 E2E**（对应 delta spec 场景）：连+发+流式；恢复桌面会话；审批批准+拒绝+前缀放行；断线重连。

## 11. Risks / Trade-offs

- WS 传输实验性、协议可能变 → 采用 daemon+proxy 官方路径规避 ws；pin 版本 + 生成类型 + 隔离协议层。
- Citadel 在 iPadOS 的 **SSH exec 通道**长连接 + 双向流式稳定性未知 → **build 首步做 spike 验证**（exec `codex app-server proxy` + `initialize` 握手）后再铺开。
- iOS 后台 socket 限制 → 断线重连 + thread/resume 恢复。
- 审批时序复杂（反向请求 + 多选项 + 多端并发，含 desktop 同连一个 daemon）→ §6 状态机；超时不自动批准。
- 受管 daemon 状态/版本与 desktop 共享 → 不依赖 desktop 内部进程模型，只依赖官方 daemon/proxy 接口与共享 `~/.codex/sessions/`。

## 12. Migration Plan

全新项目，无存量迁移。回滚 = 不部署 app；对 Mac 仅新增启动脚本 + 开启 sshd，不改 `~/.codex`。

## 13. Open Questions（带入 build）

- Citadel **SSH exec 通道**真机可靠性与后台行为，及 `codex app-server proxy` 长连接稳定性（spike 验证）。
- 受管 daemon 的 remote-control 是否需 desktop 配合开启、以及 desktop 与 daemon 的活动态共享边界（build 时实测）。
- `thread/list` 默认 `sourceKinds` 是否已含桌面 app 的 `atlas` 来源（实测确认，否则显式传 sourceKinds）。
- 审批前缀放行的 `ExecPolicyAmendment` 精确字段形状（build 时对照 schema 落地）。
