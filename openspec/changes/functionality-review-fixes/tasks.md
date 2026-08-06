# Tasks - functionality-review-fixes

> Comet build 已启动：`executing-plans` + `tdd` + 独立 worktree，单 agent 执行。

## 0. 恢复线与基线收敛

- [x] 0.1 从恢复分支已提交 HEAD 建立独立实现 worktree，重放并提交已核对的 2.2b patch 为 `19acfda2`；定向与全量 iOS 测试通过，原锁定 worktree 不改动。
- [x] 0.2 将本 change 的 `base_ref` 与计划头更新到 `19acfda2`；保留其 full-diff cwd 失效、120pt near-bottom 两组测试。
- [x] 0.3 确认当前 worktree 的 `.gitignore`、`.worktreeinclude`、`spike-3col` 等既有 dirty 状态归属，不纳入本 change。

## 1. Relay 线协议与开发机可用性

- [x] 1.1 新增 RelayProtocol 共享 wire limit；relay-server、dialout upgrader、iOS ImageEncoder/RelayTransport 全部引用；真实 NIO 端到端测试覆盖 16 KiB < frame <= 1 MiB，最终序列化帧超限在发送前显式失败。
- [x] 1.2 将 Linux `SymmetricKey: Sendable` 条件兼容纳入版本控制；在真实 Linux Swift 6.1 容器完成 RelayProtocol 42、relay-server 43、relay-dialout 48 个测试，并在 macOS 回归对应 42/43/50 个测试。
- [x] 1.3 抽取并实现 `DialoutSupervisor`，对 relay close/网络失败做可取消的 capped exponential backoff+jitter 重拨；信任拒绝、bridge 退出和用户信号为终态；macOS 通过 61 个、Linux Swift 6.1 通过 59 个 dialout 测试，并完成同进程 relay 重启重连 smoke。

## 2. Server-initiated JSON-RPC 请求

- [x] 2.1 扩展 JSONRPC response outcome 与穷尽路由；所有生成 ServerRequest 方法均被支持或显式回 `-32601`，并覆盖迟订阅补发、他端解决、断线失效与重复完成。
- [x] 2.2 实现 `item/tool/requestUserInput` store/card/response：多问题、options、free-form、secret、取消和 `autoResolutionMs` 空响应；补协议 fixture、wire、断线恢复与 Session 隔离测试。
- [x] 2.3 实现 `mcpServer/elicitation/request` URL/表单 schema UI 与 response；未知 schema fail-closed 回 error；补类型矩阵测试。

## 3. 审批与恢复正确性

- [ ] 3.1 将 command/file/permissions approval 改为 method-specific Codable DTO；协议解码失败不可批准且显式反馈。
- [ ] 3.2 完整支持 permission `fileSystem.entries`、access mode、glob depth 的知情展示与原样回授；测试拒绝/turn/session 三种结果。
- [ ] 3.3 file approval 通过 `itemId` 关联 ConversationState 的真实变更，展示 reason/grantRoot/files/diff；command approval 同步展示 reason/network context。
- [ ] 3.4 resume 只有 `inProgress` 可激活 turn；`completed/interrupted/failed/unknown` 清运行态并 drain outbox；补官方状态穷尽测试。

## 4. Session 与工作区生命周期

- [ ] 4.1 引入持久 `ConnectionIntent`，主动 Disconnect 后 tab 切换、回前台、bootstrap 均不自动连接；显式 Connect 恢复自动意图。
- [ ] 4.2 SideChatSession 收敛为 metadata，移除隐藏 ConversationStore；每个可见 side chat 仅一个通知订阅和 resume owner。
- [ ] 4.3 扩展恢复线滚动实现：流式 delta、审批卡和状态指示增长触发统一策略；自动/手动回底始终定位 bottom sentinel。
- [ ] 4.4 扩展恢复线 full-diff cache：context key + generation + stale-result guard + 显式刷新；全量 review 发起前刷新当前 snapshot。
- [ ] 4.5 TerminalSession 跟踪 exec task/generation；自然退出、terminate、断线、cwd 切换与 late response 全部正确收敛并允许重启。
- [ ] 4.6 Composer 图片加载加入 cancellation/token；旧选择、删除后迟到和视图消失不得回写；ImageEncoder 响应取消。

## 5. 全项目 Build / Verify Gate

- [ ] 5.1 根 Comet build/verify wrapper 覆盖四个 Swift Package + iOS xcodegen/build/test/analyze，并保留清晰分段失败信息。
- [ ] 5.2 运行 RelayProtocol、relay-server、relay-dialout、mac-daemon 全量测试，iOS 全量测试与 analyze；`git diff --check`、OpenSpec strict validate 全绿。
- [ ] 5.3 跑大帧 relay E2E、dialout 断开重拨、server request 交互、审批当前 schema、恢复 outbox、终端退出和图片竞态专项回归。
- [ ] 5.4 更新 verify report 与真机验收清单；真机未执行项明确保留为待验，不得以单元测试替代手感/真实网络验收。
