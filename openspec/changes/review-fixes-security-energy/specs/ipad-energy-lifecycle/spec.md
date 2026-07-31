## ADDED Requirements

### Requirement: iPad 空闲流式攒批按需调度不空转

iPad 侧流式增量攒批（`ConversationStore` 的 coalescer）SHALL **按需调度**而非常驻定时器：MUST NOT 以固定周期（如 30Hz / 33ms）在 MainActor 上无条件空转 drain。仅当有脏 delta 入队且当前无 pending flush 时，才安排一次延迟 flush；`flushCoalesced` drain 完成后 MUST NOT 自动续期，下一批脏数据到达再重新调度。空闲（无 delta）时 MUST 对主线程零唤醒。停止观察（`stopObserving`）时 MUST 仍强制最后一次 flush 兜底，不丢失尾部增量。多个并发侧聊各自的 coalescer 均遵循此纪律，空闲时不叠加唤醒。

#### Scenario: 空闲时零周期唤醒
- **WHEN** 某会话流式结束、无新 delta 到达
- **THEN** 其 coalescer 不再周期性唤醒主线程（无常驻 33ms 循环）

#### Scenario: 活跃流仍按攒批节奏刷新
- **WHEN** 连续 delta 持续到达
- **THEN** UI 仍以约 30Hz 的攒批节奏合并刷新（不逐条刷新造成 O(n²)，也不因按需调度而丢帧）

#### Scenario: 停止观察兜底不丢尾字
- **WHEN** 在仍有未 flush 的攒批内容时调用 stopObserving
- **THEN** 强制执行最后一次 flush，尾部增量完整呈现，不丢字

### Requirement: iPad 列表轮询以可见性/前台为启动前置

iPad 侧列表轮询（如 `SidebarView` 触发的 `ProjectsStore.startPolling`）SHALL 以**可见性与前台状态**作为启动前置：在异步首次加载（`loadFromServer`）返回后启动轮询前，MUST 检查任务未被取消（`!Task.isCancelled`）且应用处于前台活跃态；前台活跃态 MUST 以**实时的应用级前台真值**（`connection.foregroundActive`）判定，MUST NOT 依赖 `.task` 闭包捕获的 `scenePhase` 环境快照——该快照在 `await` 之后可能陈旧（切后台后仍读到 `.active`），会导致首拉完成误重启轮询。不满足则 MUST NOT 启动轮询。轮询启动入口（`startPolling`）自身 MUST 亦具备可见性前置，防止在不可见标签、视图消失或后台状态下因异步首拉完成而重启轮询、覆盖先前的停止。

#### Scenario: 后台或视图消失时首拉完成不重启轮询
- **WHEN** 异步首次加载进行期间应用进入后台、或承载视图消失（任务被取消 / `connection.foregroundActive == false`）
- **THEN** 首拉返回后 MUST NOT 启动轮询，先前的停止不被覆盖

#### Scenario: 前台可见时正常启动轮询
- **WHEN** 首次加载返回时任务未取消且应用处于前台活跃态
- **THEN** 正常启动列表轮询
