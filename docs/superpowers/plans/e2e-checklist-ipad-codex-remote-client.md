# iPad Codex 远程客户端 — E2E 验收清单

> change: ipad-codex-remote-client ｜ 分支: feature/20260611/ipad-codex-remote-client
>
> 状态说明：Task 0-19 已实现并通过单测/编译；Task 20 的 4 个端到端场景（Step 2-5）+ 真实帧字段校正（Step 6）需要**真机/模拟器实际操作 + 真实 Mac app-server 连接**，标注为「待实操」。本文件供实操时逐项勾选与归档录制帧。

## 已完成的自动化收尾（Task 20 Step 7-9）

- [x] Step 7：移除 spike 临时代码（`ios/CodexRemote/Spike/` 已删，无残留引用，编译通过）
- [x] Step 8：本验收清单文档
- [x] Step 9：全量单测通过（见末尾）

> 注：`SpikeIntegrationTests.swift` 保留——它是环境变量驱动的真实 SSH 握手集成测试，是 Step 2 真机验证的自动化辅助工具（非临时 spike）。

## 连接链路已验证事实（2026-06-11）

- 已在 **iPad 模拟器 + 真实 Citadel SSH 连本机 Mac**（192.168.9.100）exec `codex app-server --listen stdio://`，发 `initialize` 收到含 `userAgent`/`codexHome` 的响应——`SpikeIntegrationTests.testWithExecInitializeHandshakeAgainstRealServer` PASS。`withExec` 长驻闭包 + 换行分帧在 iOS 运行时验证通过。
- app UI 在模拟器渲染正常：`ConnectionConfigView`（连接配置）已截图确认。
- **传输方案**：经实测，`codex app-server proxy` 在本机不可用（远程控制 disabled + control socket 被非受管实例占用），已改用 `codex app-server --listen stdio://`（SSH exec 每连接起独立 app-server，共享 `~/.codex/sessions/`）。

## 待实操的 E2E 场景（Task 20 Step 1-6）

### 前置（Step 1）
- [ ] Mac 与 iPad 同 LAN；Mac 开启「远程登录」(sshd)。
- [ ] Xcode 选真机 iPad（或模拟器）运行 app。
- [ ] `ConnectionConfigView` 填 Mac IP / SSH 用户名 / 密码（或私钥），点「连接」。

### 场景 1 — 连 + 发 + 流式（tasks 7.1，conversation-streaming）
- [ ] 连接进入 ready
- [ ] 新建对话 → composer 发「列出当前目录文件」
- [ ] `item/agentMessage/delta` 增量渲染正文
- [ ] 触发命令时 `outputDelta` 渲染命令输出
- [ ] `turn/completed` 后回合结束
- [ ] 📎 录制原始 JSON 帧归档到本文件「录制帧」节

### 场景 2 — 恢复桌面 app 会话（tasks 7.2，session-management）
- [ ] 前置：Mac 桌面 Codex app 里先建一个会话
- [ ] iPad 左栏出现该会话（按 cwd 分组）
- [ ] 若不可见 → 校正 `ProjectsStore.listParamsForDesktopVisibility()` 的 `sourceKinds`（设计 §13 待确认项）
- [ ] 选中 → `thread/resume` 加载历史 → 可继续对话

### 场景 3 — 审批闭环（tasks 7.3，approval-flow）
- [ ] 发会触发命令/文件修改审批的指令 → 出现多选项审批卡
- [ ] 路径 A：点「是」→ 渲染执行结果
- [ ] 路径 B：点「否」→ Codex 收到拒绝
- [ ] 路径 C：点「是，且本会话放行此前缀」→ 同前缀后续不再弹卡
- [ ] 左栏「等待批准」徽标未决时出现、解决后消失
- [ ] 📎 录制审批 server request + response 帧，核对 v2 `accept`/`decline`/`acceptWithExecpolicyAmendment` 形状

### 场景 4 — 断线重连 + 鉴权失败（tasks 7.4，remote-connection）
- [ ] A：连接后断 WiFi 几秒再恢复 → 「重连中」横幅 → 自动重建 SSH + `initialize` + `thread/resume`
- [ ] B：故意填错密码 → 显示明确「SSH 鉴权失败」
- [ ] C：SSH 通但 app-server 不可达 → 显示「app-server 不可达」

### 字段校正（Step 6）
用上面录制的真实帧校正并补回归测试：
- [ ] `ThreadReducer` 字段名（`itemId`/`delta`/`itemType`/`command`/`kind`/diff 字段）
- [ ] `ApprovalStore.handle` 取的参数键（尤其 `FileChangeApprovalParams` 的 changes/file/diff 路径）
- [ ] `serverRequest/resolved` 的 requestId/threadId 字段名
- [ ] 把真实帧序列存为新 fixture + 补一条 `ThreadReducerTests` 真实帧回归
- [ ] 每次校正后重跑相关单测确认 PASS

## 录制帧归档

> 实操时把真实 JSON 帧粘贴到此处（按场景分节）。

```
（待实操填充）
```

## 全量测试基线（自动化收尾时）

- 全量单测：见 Step 9 运行结果（提交记录）。
- 1 项 skip = `SpikeIntegrationTests`（需环境变量提供 SSH 凭证，真机/手动验证时跑）。
