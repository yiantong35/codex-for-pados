## Context

本 change 基于功能 review 的源码、生成协议与测试交叉核对。问题不是一个孤立 UI bug，而是四条端到端链路的契约不一致：

1. iOS 允许约 1 MiB，relay-server 允许 1 MiB，dialout decoder 却默认只允许 16 KiB；
2. JSON-RPC 能接收所有 server request，但生产协调器仅消费审批，需用户输入的 turn 无响应；
3. 审批 UI 仍按旧字段手工解字典，与仓库内生成协议不一致；
4. 多个 View/Store 把“对象仍存在”误当作“数据仍属于当前上下文”，导致断线、切线程、流式增长和异步图片任务产生 stale 状态。

恢复审计同时找到 `worktree-workspace-ui-review-fixes-2`：其 14/15 项已提交，最后的 `ProgressCardBar` button trait 与说明留在未提交 diff；它已实现 cwd 级 full-diff 失效和 120pt 近底几何判定，但没有解决同 cwd 新修改、迟到 fetch、流式 delta/审批卡增长和 bottom target。因此它是本 change 的前置依赖，不是替代品。

## Goals / Non-Goals

**Goals**

- 13 项 review 发现全部以生产路径行为闭合，并用当前生成协议或真实传输栈测试。
- 同一 wire limit、request schema、connection intent、content ownership 均只有一个真源。
- 断线/切换/取消/迟到结果均显式建模，不依赖隐含 SwiftUI 生命周期偶然正确。
- build/verify 覆盖整个仓库，而非只编译 iOS target。

**Non-Goals**

- 不改变 AES-GCM、X25519、Ed25519、TOFU、relay 零知识转发或 `RelayProtocolVersion.tag`。
- 不把 iPad 变成任意 dynamic tool 的执行宿主；未支持的 server request 必须显式拒绝。
- 不在此 change 合并其它并行 security/UI review 的新发现；超过初始任务 50% 的增量另开 change。
- 不在 plan-ready 阶段选择 branch/worktree、执行方式或 TDD 模式；这些在用户切换模型并恢复 build 后确认。

## Decisions

### D1. 先收尾恢复线，再固定实现基线

`workspace-ui-review-fixes-2` 先完成未提交的 2.2b、复跑验证、生成报告并 archive。之后把本 change rebase/重建在实际集成 HEAD 上并更新 `base_ref`。禁止直接把旧 worktree 的全部 dirty state复制进本 change；以正常 commit/rebase/cherry-pick 保留可追溯历史。

### D2. Wire limit 下沉到 RelayProtocol，最终帧双重防线

新增 `RelayWireLimits.maxMessageBytes = 1 << 20`。relay-server 的 accumulator/upgrader、relay-dialout 的 `NIOWebSocketClientUpgrader(maxFrameSize:)`、iOS ImageEncoder 均引用它。iOS `RelayTransport.send` 在加密并 JSON 编码后用 UTF-8 实际字节数做最终检查；超限返回可呈现错误，不以断 socket 作为输入校验。

NIO 测试必须使用真实 client/server upgrader，发送 16 KiB 以上且 1 MiB 以下文本帧，证明不是只测常量。文本输入同样受最终帧检查，图片预算只作为提前降采样优化。

### D3. Dialout 是受监督的长驻进程

把单次 `connect().wait(); closeFuture.wait(); exit` 抽为可测 `DialoutSupervisor`：瞬时连接/关闭失败按带 jitter 的指数退避重拨，成功握手后重置 attempt；bridge 子进程跨瞬时 relay 断开保留。信任拒绝、bridge 子进程退出、用户 SIGINT/SIGTERM 是终态，必须停止重拨并精确回收自己的子进程。重拨不在 relay 层缓存/重放应用数据，重连后的状态仍由 daemon resume 收敛。

### D4. Server request 使用单一路由和显式 response outcome

`JSONRPCClient` 的 request handler 从“只能返回成功 AnyCodable”改为 `ServerRequestOutcome.result/error/deferred`。路由器穷尽匹配仓库生成的 `ServerRequest` 方法：

- `item/tool/requestUserInput`：入队交互卡，支持 options、free-form、多个 question、取消与 `autoResolutionMs`；响应严格对齐 `ToolRequestUserInputResponse`。
- `mcpServer/elicitation/request`：支持 URL/表单两类当前 schema，按字段类型渲染控件并回 `McpServerElicitationRequestResponse`。
- 三类 approval：交给 ApprovalStore，响应由用户动作 deferred 完成。
- `item/tool/call`、auth refresh、attestation 等本客户端未实现方法：立即回 JSON-RPC method-not-supported/error，不静默挂起。

同一 request id 只能有一个 owner 和一次终态 response；断线时 deferred 请求 fail-closed 保留/恢复，不自动接受。

### D5. 审批按 method 类型化解码

删除核心路径上的 `[String: Any]` 字段猜测。为三类 v2 approval 建立与生成 TS 对齐的 Swift Codable DTO：

- permissions 保留 `read/write/globScanMaxDepth/entries`，entries 的 `path` 与 `access(read/write/deny)` 原样展示和回授；
- file change 保留 `threadId/turnId/itemId/startedAtMs/reason/grantRoot`，由 `ConversationView` 用 `itemId` 关联真实 `.fileChange` item 后传给 card；
- command 展示 `reason/cwd/commandActions/networkApprovalContext` 和服务端 amendment。

解码失败时显示不可批准的协议错误卡并回明确错误，禁止生成空白但可点击“批准”的卡。

### D6. Resume 状态只允许官方 inProgress 激活

快照存在 status 时，只有 `inProgress` 可以设置 `activeTurnId`；`completed/interrupted/failed` 清 active turn、in-flight items 并放行 outbox。未知未来 status 采用 fail-safe 终态处理并记录诊断，禁止凭未知字符串推断仍在运行。测试覆盖全部生成枚举值和 unknown。

### D7. 连接意图与连接相位正交

`Session` 增加 `ConnectionIntent.automatic/userDisconnected`。用户 Disconnect 先设置 intent，再关闭连接；只有显式 Connect/重配/新增机器才恢复 automatic。`shouldAutoConnect` 同时检查 intent 与 phase；tab 切换、app foreground、bootstrap 均复用这一决策。异常掉线仍按既有自动恢复。

### D8. 每个侧聊只有一个 ConversationStore owner

`SideChatStore` 只保存 fork metadata（threadId/title/selection），不提前创建隐藏 ConversationStore。可见的 `ConversationView` 创建并拥有唯一 store、订阅与 resume handler；切换/关闭取消对应生命周期，重新选中用 `thread/resume` 获取权威历史。测试以 JSONRPCClient continuation 数和 resume 调用数证明无双消费者。

### D9. 滚动由内容高度增长驱动，目标永远是 bottom sentinel

保留恢复线的 120pt GeometryReader/PreferenceKey 近底策略，在此基础上增加内容高度 revision：流式 delta 改变既有 item、审批卡新增/恢复、running indicator 变化均触发统一 `contentDidGrow`。近底时滚到 `bottomSentinelID`；离底时只显示新消息入口。入口也滚到 sentinel，而不是 last item/indicator。

### D10. Full diff 是有身份和世代的 snapshot

snapshot key 至少含 `cwd + threadId + rpcIdentity + refreshGeneration`。上下文变化立即清空旧内容并取消/作废旧请求；返回时再次比对 key，迟到结果直接丢弃。同 cwd 外部修改没有可靠通知，因此提供显式刷新入口；点击“发起全量审查”先完成一次当前 key 的 refresh，再启动 review，确保可见 snapshot 与动作上下文一致。恢复线的 cwd cache 测试保留并扩展为 race/refresh 测试。

### D11. Terminal 用 process generation 收敛生命周期

保存 `execTask` 与 generation/processId。`command/exec` 最终 response 到达时，仅当 generation 仍为当前进程才清 `running/processId` 并输出退出状态。terminate 立即让 `startIfNeeded` 可再次启动，但旧 response 不得清新 pid；断线和 cwd 切换同样使 generation 失效。不得把 processId 非空等同于 process 仍活着。

### D12. 图片任务可取消且写回前校验 token

Composer 保存当前 load task 和 UUID token；选择、删除、发送、视图消失均取消旧任务并换 token。ImageEncoder 在解码/缩放/多轮压缩之间检查 cancellation。写回 `imageDataURL/error` 前必须确认 token 和 `photoItem` 仍匹配。逻辑抽成可注入 loader 以确定性测试 A 慢于 B、删除后迟到、任务取消三种竞态。

### D13. Comet 根 gate 覆盖所有可交付组件

根 `comet.yaml` 改用 `scripts/comet-build-check.sh` / `scripts/comet-verify-check.sh`。build 顺序覆盖 RelayProtocol、relay-server、relay-dialout、mac-daemon 与 iOS；verify 跑四包 tests、iOS tests、`xcodebuild analyze`、OpenSpec strict validate 和 diff check。Linux 条件扩展必须在真实 Linux Swift 6 环境验证；本机没有 Linux 时 verify 保持未完成，不以 macOS 通过替代。

## Risks / Trade-offs

- 交互式 MCP 表单范围较大：只实现生成 schema 中的 primitive/enum/array/object 组合；未知 schema 显式拒绝，禁止宽松猜测。
- dialout 长驻重拨会增加后台网络唤醒：采用有上限退避+jitter，连接健康时零轮询；用户主动退出是硬终态。
- 内容高度 preference 可能频繁回调：只在高度增长或近底状态变化时处理，不加 timer；流式渲染仍沿用现有 30 Hz coalescer。
- 类型化审批可能暴露服务端版本漂移：这是预期 fail-closed 行为，必须同时保留明确错误文案和协议 fixture 测试。
- 当前 worktree 为 detached HEAD 且存在用户未跟踪文件；build 恢复时先选择隔离方式，绝不覆盖或顺带提交 `.gitignore`、`.worktreeinclude`、`spike-3col` 等无关状态。

## Recovery

恢复后的执行入口固定为：

1. 确认 `worktree-workspace-ui-review-fixes-2` 的 2.2b 已提交、验证和 archive；若未完成，从其现有 dirty diff 续做，不重写前 14 项。
2. 更新本 change `base_ref` 和 plan front matter 到集成后的 HEAD。
3. 重新核对 `ReviewTabView` / `ConversationView` 重叠项，保留恢复线测试，再从 tasks.md 第一项未完成任务继续。
4. 用户明确选择 isolation、execution mode、TDD 后才开始任何 build/实现。
