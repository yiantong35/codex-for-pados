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
