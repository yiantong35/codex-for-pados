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
- `appearance-locale`: 多语言（中/英）运行时切换 + 深浅色主题（浅/深/跟随系统） + 右上角全局设置入口。

### Modified Capabilities

（无——全新项目，`openspec/specs/` 当前为空。）

## Impact

- **新代码**：iPadOS SwiftUI app（Xcode 工程）、Mac 端启动脚本。
- **新依赖**：iPad 端引入 SSH 库（候选 Citadel，基于 Apple swift-nio-ssh）；JSON-RPC / WebSocket 走系统 `URLSessionWebSocketTask`。
- **外部依赖**：`codex` CLI / app-server（当前 Mac 环境 codex-cli 0.133.0）。WebSocket 传输官方标注"实验性"，需 pin Codex 版本并从 `codex app-server generate-json-schema` 生成协议类型。
- **系统/平台**：iOS 本地网络权限（Info.plist）、后台 socket 保活限制；Mac 需开启"远程登录"(sshd)。
- **不影响**：Codex 引擎本体、云端 Codex、Mac 现有 `~/.codex` 数据（只读连接，不修改存储结构）。
