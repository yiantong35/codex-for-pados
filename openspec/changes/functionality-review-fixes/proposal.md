## Why

第二轮全项目功能 review 在 `1e5ec734` 上确认了 13 个真实缺口：大消息在 dialout 的 16 KiB 解码边界被断开、交互式 server request 无响应、审批协议已漂移、恢复状态和多项 UI 生命周期不收敛。另有一条此前中断的 UI review fix 分支已找回，但尚未合入当前基线；本 change 需要在复用其有效成果的前提下完成剩余功能闭环。

## What Changes

- 先恢复并完成 `worktree-workspace-ui-review-fixes-2` 的最后 1/15 项，落线后再重定本 change 的 `base_ref`，避免重复修改 `ReviewTabView` / `ConversationView`。
- 把 relay 最大消息大小提升为 RelayProtocol 的单一共享常量，让 relay-server、relay-dialout 和 iOS 使用同一 1 MiB 上限；dialout 显式配置 NIO WebSocket decoder，并在 iOS 发送最终序列化帧前做真实字节校验。
- 将 Linux `SymmetricKey: Sendable` 兼容补丁纳入版本控制，并以真实 Linux Swift 构建验证，而不是只在 macOS 上假定可用。
- 为 `relay-dialout` 增加可取消、带抖动退避的连接监督循环；瞬时断网、relay 重启和 15 分钟空闲回收后无需人工重启命令。
- 建立 server request 路由：完整支持 `item/tool/requestUserInput` 与 `mcpServer/elicitation/request`，其余未支持方法显式回 JSON-RPC error，不再静默悬挂 turn。
- 将三类审批请求改为按 method 类型化解码；支持 `fileSystem.entries`、展示访问模式并原样回授；文件审批按 `itemId` 关联真实 file-change item，展示 `reason` / `grantRoot` / 变更内容。
- 恢复快照只把官方 `inProgress` 视为运行中，`interrupted` 和其它终态必须清理 active turn 并放行 outbox。
- 用户主动 Disconnect 形成持久连接意图，tab 切换和回前台不得擅自重连。
- 侧聊只保留一份会话状态所有者；对话滚动对流式文本和审批卡增长敏感，并始终滚到真正的 bottom sentinel。
- 全量 review 使用带上下文身份和请求世代的 snapshot；支持显式刷新、丢弃迟到结果，发起审查前刷新当前 cwd，避免展示与执行上下文不一致。
- 终端在 shell 自然退出、手动 terminate、断线和 late response 下均正确收敛，可在同 cwd 重启。
- 图片加载任务可取消并带 selection token，旧选择或已移除附件的迟到编码结果不得覆盖当前状态。
- 扩展 Comet build/verify gate，使根级验证覆盖 RelayProtocol、relay-server、relay-dialout、mac-daemon、iOS tests 与 analyze。

## Capabilities

### New Capabilities

- `ipad-interactive-server-requests`: iPad 对需要用户输入的 server-initiated JSON-RPC 请求提供可交互 UI、协议正确响应、取消/自动解决和未支持方法显式错误语义。

### Modified Capabilities

- `relay-e2e-transport`: 三端共享同一消息上限，发送前按最终帧校验，Linux 构建受验证。
- `relay-trusted-reconnect`: dev dialout 的物理连接断开后自动重拨，主动退出与信任失败仍为终态。
- `ipad-approval-handling`: 审批按当前生成协议类型化处理，权限 entries 和文件变更知情展示/响应保持一致。
- `ipad-reconnect-resync`: resume 对官方 turn status 做穷尽式终态收敛，`interrupted` 不得恢复成运行中。
- `ipad-multi-connection`: 自动连接决策尊重用户主动断开意图。
- `ipad-side-chat`: 每个侧聊线程只允许一个活动 ConversationStore/通知消费者。
- `ipad-conversation-ux`: 流式文本和审批卡增长遵守近底自动滚动策略，新消息入口滚到真实底部；图片附件选择无迟到覆盖。
- `ipad-review-panel`: 全量 diff snapshot 随上下文和刷新世代失效，迟到结果不得串工作区，发起审查与展示快照一致。
- `ipad-bottom-terminal`: shell 自然/手动退出后终端状态收敛并可重启，旧进程迟到响应不得影响新进程。

## Impact

- Relay：`packages/RelayProtocol`、`relay-server`、`relay-dialout` 的线协议边界与 dev 连接生命周期。
- iOS：RPC/server-request、审批、resume、Session/SessionsManager、SideChat、Conversation、Review、Terminal、Composer/ImageEncoder。
- 测试：新增真实 NIO 大帧、server request response、当前协议 fixture、恢复状态矩阵、连接意图、单消费者、滚动增长、终端退出、图片取消和 Linux build 验证。
- 工程：`comet.yaml` 与根级 build/verify wrapper 扩为全项目 gate；不修改密码学算法、TOFU、relay 零知识语义或协议版本 tag。
