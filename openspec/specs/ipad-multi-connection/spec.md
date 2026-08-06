# ipad-multi-connection Specification

## Purpose
TBD - created by archiving change multi-connection-tabs. Update Purpose after archive.
## Requirements
### Requirement: 多连接会话容器（Session 隔离）

系统 SHALL 以 sessions 管理层持有多个 Session，每个 Session 对应一台机器的连接，并自带独立的连接状态与整套功能 store（会话列表、环境、MCP、Skills、Plugins、Hooks、终端等）。切换活跃 tab 时，系统 SHALL 把当前 Session 的 store 注入界面，各 Session 之间的会话状态互不污染。

#### Scenario: 每 Session 独立 store

- **WHEN** 存在多个已连接的 Session
- **THEN** 每个 Session 拥有各自的连接（rpc/phase）与功能 store 实例
- **AND** 一个 Session 的会话列表/环境数据不出现在另一个 Session

#### Scenario: 切换 tab 不串台

- **WHEN** 用户在 tab A 打开某会话后切到 tab B，再切回 tab A
- **THEN** tab A 恢复其原会话与选中状态
- **AND** tab B 展示的是 B 自己的会话，不混入 A 的内容

### Requirement: tab 栏与机器管理入口

系统 SHALL 在与会话容器同级的位置提供 tab 栏，每台机器一个 tab，并提供添加机器、移除机器、重命名机器、连接/断开某 tab 的入口，且不依赖设置页。机器管理入口（连接/断开/重命名/移除）SHALL 通过 tab 上一个**可见的管理入口**呈现，SHALL NOT 仅依赖长按/上下文菜单等隐藏手势触发。该可见入口 SHALL 在触控点击、指针点击与外接键盘（聚焦后回车/空格激活）下均可触达并生效。机器"退出"语义为断开或移除该 tab 的连接，系统 SHALL NOT 调用 `account/logout`，SHALL NOT 改变 Mac 上 codex desktop 的账号登录态。断开与移除语义 SHALL 区分：**断开**仅断连接、tab 保留于 tab 栏、机器仍在持久化列表可重连；**移除**从 tab 栏删除该 tab 且从持久化列表删除该机器。**重命名**仅修改该机器持久化的显示名、不影响连接；空白名 SHALL 被忽略（保持原名）。添加机器成功后系统 SHALL 自动切到该机器的 tab 并发起连接。

#### Scenario: 添加机器新增 tab 并自动连接

- **WHEN** 用户经 tab 栏的添加入口填写机器信息并保存
- **THEN** tab 栏新增该机器对应的 tab
- **AND** 该机器进入持久化机器列表
- **AND** 自动切到该 tab 并发起连接

#### Scenario: 断开某 tab 连接（保留 tab）

- **WHEN** 用户对某 tab 执行断开
- **THEN** 该 Session 的连接断开
- **AND** 该 tab 仍保留在 tab 栏、机器仍在持久化列表
- **AND** 其余 tab 的连接不受影响
- **AND** 不发出 `account/logout` 请求

#### Scenario: 移除机器（删除 tab 与机器）

- **WHEN** 用户对某 tab 执行移除
- **THEN** 该 tab 从 tab 栏消失且该机器从持久化列表删除
- **AND** 其余 tab 与其连接不受影响

#### Scenario: 断开/移除入口可实际触达

- **WHEN** 用户点击某 tab 上可见的管理入口（⋯ 菜单）
- **THEN** 系统呈现连接/断开/重命名/移除入口
- **AND** 点击「断开」触发该 tab 断开、点击「移除」触发该 tab 移除
- **AND** 该可见入口在横屏与竖屏、触控点击、指针点击与外接键盘（聚焦后回车/空格激活）下均可触达并生效

#### Scenario: 重命名机器 tab

- **WHEN** 用户在某 tab 的 ⋯ 菜单点击「重命名」并输入新名保存
- **THEN** 该 tab 显示名更新为新名并持久化（重启后保留）
- **AND** 该机器的连接状态不受影响
- **AND** 若输入为空白，则忽略、保持原名

### Requirement: 机器列表持久化与迁移

系统 SHALL 将机器列表（每台含显示名、relay 连接标识、上次活跃标记）持久化。relay 连接标识 SHALL 为 relay URL / sessionId / dev identity 公钥等 relay 配对建立连接所需字段；机器条目 SHALL NOT 再持有 SSH host / user / SSH 端口 / control socket 路径字段。鉴权与身份验证密钥由 relay E2E（`RelayE2EKeyManager`，见 `relay-e2e-transport`）管理，SHALL NOT 复用任何 SSH 密钥。

app 尚未上线，无存量单组连接配置或 SSH 机器需要迁移；`MachineConfig` SHALL NOT 保留 legacy flat-format→SSH 的解码迁移路径，也 SHALL NOT 保留 SSH 便利构造或 SSH 兼容字段 shim。

#### Scenario: 机器列表持久化

- **WHEN** 用户添加或修改机器后重启 app
- **THEN** 机器列表按上次保存的内容恢复，每台机器的 relay 连接标识完整保留

#### Scenario: 机器条目仅含 relay 标识

- **WHEN** 检视持久化的机器条目
- **THEN** 每台机器仅含显示名、relay 连接标识（relay URL / sessionId / dev identity 公钥）与上次活跃标记
- **AND** 不含任何 SSH host / user / 端口 / control socket 字段

#### Scenario: 旧配置迁移

- **WHEN** 升级前存在旧的单组连接配置或历史 SSH 机器持久化数据
- **THEN** 系统不执行任何迁移（app 未上线，无存量真实用户配置），旧 SSH 相关数据按开发期脏数据直接丢弃，不再转为机器列表首项
- **AND** 机器列表以 relay-only 形态重建，不因旧数据缺失或丢弃而阻断持久化/恢复

### Requirement: 机器数量上限

系统 SHALL 限制机器数量上限为 10 台。达到上限时 SHALL 阻止继续添加并给出可感知的提示。

#### Scenario: 达到上限拦截

- **WHEN** 机器列表已有 10 台且用户尝试添加第 11 台
- **THEN** 系统拒绝添加
- **AND** 给出已达上限的提示

### Requirement: 连接页 gating 重定

系统 SHALL 取消全屏连接页概念：当机器列表为空时，SHALL 显示"添加第一台机器"引导；当机器列表非空时，SHALL 直接进入主界面（tab 栏与各 tab 自身连接态），不再以全屏连接配置页拦截。

#### Scenario: 零机器显示引导

- **WHEN** 全新装机且机器列表为空
- **THEN** 显示"添加第一台机器"引导
- **AND** 不显示旧的全屏连接配置页

#### Scenario: 有机器直入主界面

- **WHEN** 机器列表非空时冷启动
- **THEN** 直接进入主界面（tab 栏）
- **AND** 不以全屏连接页拦截，即使某些 tab 尚未连上

### Requirement: 后台 tab 连接策略

系统 SHALL 为非活跃（后台）tab 采用"保连 + 降频"策略：后台 Session SHALL 保持连接不断开；SHALL 保留轻量列表级订阅（会话运行态 `thread/status/changed`、列表变动 `thread/started`/`deleted`/`name/updated`）以驱动徽标实时更新；SHALL 退订当前会话的正文级订阅（`item/updated`、turn 正文 delta）。Session 转为活跃时 SHALL 恢复正文订阅并对当前会话 `thread/resume` 补正文最终态。系统 SHALL NOT 让后台 tab 的正文级流量不受控地随 tab 数膨胀。

#### Scenario: 转后台保留列表订阅、退订正文

- **WHEN** 某 tab 从活跃切为后台
- **THEN** 该 Session 连接保持
- **AND** 运行态与列表级广播仍被接收（徽标可实时更新）
- **AND** 当前会话的正文级订阅被退订

#### Scenario: 转前台恢复并补正文

- **WHEN** 某后台 tab 切回活跃
- **THEN** 恢复正文级订阅
- **AND** 对当前会话 resume 补正文最终态
- **AND** 会话状态正确恢复

### Requirement: tab 通知状态标记

系统 SHALL 在每个 tab 上以单个紧凑状态标记聚合该 Session 内所有会话的最高优先级状态，优先级从高到低为：系统错误（红、错误符号、闪烁）> 等待审批或输入（橙、注意符号、闪烁）> 运行中（绿、运行符号、常亮）> 未读（蓝、圆点、常亮）> 无。连接异常时 SHALL 显示灰色断连符号。颜色与符号 MUST 同时编码状态；系统错误与连接异常语义正交。仅尚未创建 Session 的懒连 tab 不显示标记，后台 tab 标记由列表级广播实时更新。

#### Scenario: 聚合取最高优先级

- **WHEN** 某 tab 连接就绪且其 Session 同时有会话在运行且有会话等待审批
- **THEN** 该 tab 状态标记显示等待审批（橙、注意符号、闪烁），不被运行态稀释

#### Scenario: 断线 tab 显示灰色断连标记

- **WHEN** 某 tab 连接 phase 非 `.ready`(重连中/失败/断线)
- **THEN** 该 tab 显示灰色断连符号表达连接异常

#### Scenario: 未连接 tab 无状态标记

- **WHEN** 某 tab 尚未发起连接(未建 Session 的懒连态)
- **THEN** 该 tab 不显示状态标记

#### Scenario: 后台 tab 状态标记实时更新

- **WHEN** 某后台机器的会话进入等待审批且其连接就绪
- **THEN** 对应 tab 的状态标记实时变为等待审批（橙、注意符号、闪烁）

### Requirement: 多连接布局与输入适配基线

系统 SHALL 保证 tab 栏与机器管理入口在横屏与竖屏下均可用，tab 栏在放不下时横向滚动，并兼容触摸手势、软键盘与外接键盘操作。外接键盘 SHALL 基础可用（文本输入、系统标准聚焦/关闭如 Tab/Esc，不崩不卡）；本能力 SHALL NOT 引入自定义快捷键（自定义快捷键属后续独立变更）。

左边栏、中栏与右边栏 SHALL 由自绘布局承载列宽与拖拽（SHALL NOT 依赖 `NavigationSplitView` 系统列/`.inspector` 托管的列宽调整）。左边栏与右边栏 SHALL 各自保持可拖拽调整宽度，且拖拽一侧 SHALL NOT 连带改变另一侧的宽度（左右宽度相互独立、完全解耦）；系统 SHALL NOT 为满足此独立性而固定任一栏的宽度。左/右列的宽度调整入口 SHALL 保留可拖拽能力，其视觉把手 MAY 隐藏（不显示可见的把手装饰），但拖拽调宽 SHALL 仍可用。

每一可调栏的最大宽度 SHALL 为容器总宽的三分之二（2/3），并随横竖屏与屏幕尺寸动态适配（SHALL NOT 使用固定像素上限），同时 SHALL 保证中栏保留一个最小可用宽度不被压没。拖拽调宽在横屏与竖屏下 SHALL 行为一致（竖屏 SHALL NOT 退化为系统浮层导致无法调宽）。拖拽过程 SHALL 保持跟手、SHALL NOT 出现慢速拖动时的可见抖动或掉帧。

#### Scenario: 横竖屏 tab 栏可用

- **WHEN** 设备在横屏或竖屏
- **THEN** tab 栏可见且可切换/管理 tab
- **AND** 放不下时可横向滚动

#### Scenario: 软键盘不遮挡

- **WHEN** 软键盘弹出（如在添加机器表单输入）
- **THEN** tab 栏与当前输入框不被软键盘遮挡

#### Scenario: 外接键盘基础可用

- **WHEN** 连接外接键盘进行文本输入与标准聚焦/关闭操作
- **THEN** 输入与系统标准键（Tab/Esc）正常工作，界面不崩不卡
- **AND** 不依赖本能力提供的自定义快捷键

#### Scenario: 左右栏拖拽宽度相互独立

- **WHEN** 用户拖拽调整左边栏宽度
- **THEN** 右边栏宽度保持不变
- **WHEN** 用户拖拽调整右边栏宽度
- **THEN** 左边栏宽度保持不变
- **AND** 左右两栏均仍可各自拖拽调宽（未被固定）

#### Scenario: 隐藏列把手仍可拖拽调宽

- **WHEN** 界面未显示可见的列拖拽把手装饰
- **AND** 用户在列分隔位置拖动
- **THEN** 对应列宽度随拖动调整

#### Scenario: 可调栏最大宽度为总宽 2/3 且横竖屏一致

- **WHEN** 用户在横屏或竖屏下把某一可调栏往宽拖到底
- **THEN** 该栏宽度停在容器总宽的 2/3
- **AND** 中栏仍保留最小可用宽度
- **AND** 切换横竖屏后该 2/3 上限随新的总宽重新计算

#### Scenario: 慢速拖动跟手不抖

- **WHEN** 用户缓慢拖动列分隔线
- **THEN** 列宽随手指平滑变化、跟手
- **AND** 不出现来回抖动或明显掉帧

#### Scenario: 退后台/冷启动列宽恢复

- **WHEN** 用户调整过列宽后，app 进程被系统回收或经历冷启动
- **AND** 用户重新进入工作区
- **THEN** 三栏列宽恢复到上次调整的值（从持久化存储读取）
- **AND** 若无历史记录则使用默认列宽

#### Scenario: 切 session 列宽各自独立

- **WHEN** 用户在机器 A 的 tab 下调整了列宽
- **AND** 切换到机器 B 的 tab
- **THEN** 机器 B 显示其自己记忆的列宽（不被机器 A 的调整覆盖）
- **WHEN** 切回机器 A 的 tab
- **THEN** 恢复机器 A 之前调整的列宽

### Requirement: App 系统级生命周期能耗

区别于「后台 tab 连接策略」（那是 tab 之间的活跃/非活跃切换），本需求针对**整个 app 进入 / 离开系统后台**（`scenePhase`）时的能耗行为。

当 app 整体进入系统后台时，系统 SHALL 向 `SessionsManager` 缓存的**全部** Session（不仅当前活跃 tab 对应的 Session）传播 app 级后台状态，使每个连接的 transport（connection 级 `setForeground(false)`）暂停重连、不建新 WebSocket、不执行加密握手。此 app 级前后台状态独立于 tab 级「保连 + 降频」轮询开关（tab 后台仍保连、徽标 live）。app 回到前台时 SHALL 向全部缓存 Session 恢复前台状态。系统 SHALL NOT 让非当前活跃的缓存连接在 app 后台期间继续重连或握手。

正在消费某会话正文通知流的订阅任务���SHALL 在其宿主视图退出（或订阅目标 threadId 变化）时被显式停止，SHALL NOT 在视图消失后仍存活并持续消费通知流、唤醒主线程。切换会话 SHALL NOT 导致存活订阅任务数量随切换次数累积增长。

Relay 传输的断线重连循环在退避等待结束后、创建新通道前，SHALL 再次确认处于前台；若退避期间 app 已转入后台，SHALL 继续等待回到前台后才创建通道与握手。

新增机器并连接时，系统 SHALL 只发起一次建连（transport factory 每次新增机器只被调用一次），SHALL NOT 因激活与连接两条路径重复触发而并行启动两套建连任务。

#### Scenario: app 进系统后台时全部缓存连接暂停

- **WHEN** 存在多台已连接机器的缓存 Session，app 整体进入系统后台
- **THEN** 全部缓存 Session 收到 app 级后台状态（transport 层 `setForeground(false)`）
- **AND** 非当前活跃的连接也不再重连 / 建 WebSocket / 执行握手
- **WHEN** app 回到前台
- **THEN** 全部缓存 Session 恢复前台状态

#### Scenario: 对话视图退出释放正文订阅

- **WHEN** ConversationView 退出，或其订阅目标 threadId 变化
- **THEN** 旧会话的正文通知订阅任务被停止
- **AND** 反复切换 N 次对话后，存活的订阅任务数量恒为当前单个会话的数量（不随切换次数累积）

#### Scenario: 退避期间转后台不建通道

- **WHEN** Relay 重连处于退避 sleep 中，其间 app 进入后台
- **THEN** 退避结束后不创建新通道、不握手
- **AND** 等待 app 回到前台后才创建通道并握手

#### Scenario: 新增机器只建连一次

- **WHEN** 通过「添加机器并连接」新增一台机器
- **THEN** 该机器的 transport factory 只被调用一次
- **AND** 不并行启动两套建连任务

### Requirement: 自绘三栏在窄窗下降级不横向溢出

自绘三栏布局 SHALL 在容器宽度低于「三栏全开所需最低宽」（左栏 min + 中栏 min + 右栏 min + 两分隔线之和）时**降级呈现**而 SHALL NOT 横向溢出容器。降级策略 SHALL 保证内容宽度之和不超过容器宽度：当空间不足以容纳三栏最低宽时，系统 SHALL 按宽度断点自动收起一侧或两侧侧栏（或改以 overlay 呈现侧栏），使主内容（中栏）始终完整可见、不被裁剪、不产生横向滚动溢出。

此需求覆盖分屏（Split View）与 Stage Manager 的窄窗尺寸，SHALL NOT 假设容器宽度恒为竖屏/横屏全屏尺寸。

#### Scenario: 窄窗低于三栏最低宽时收起侧栏
- **WHEN** 容器宽度低于三栏全开所需最低宽（如分屏/Stage Manager 窄窗）
- **THEN** 系统 SHALL 自动收起侧栏（或改 overlay），使三部分宽度之和不超过容器宽度
- **AND** 布局 SHALL NOT 横向溢出、中栏内容 SHALL 完整可见

#### Scenario: 恢复到足够宽度时侧栏可再展开
- **WHEN** 容器宽度回到足以容纳三栏最低宽
- **THEN** 被自动收起的侧栏 SHALL 可再次展开（并遵循既有列宽持久化/恢复行为）
- **AND** 布局 SHALL NOT 溢出

### Requirement: 移除配对机器需二次确认

移除机器（从 tab 栏与持久化列表删除该机器）SHALL 需要一次**二次确认**再执行，SHALL NOT 由单次点击直接永久删除配置并断连，避免误触后需重新配对。断开与移除的语义区分（断开保留机器、移除删除机器）保持不变。

机器管理菜单 SHALL 依据当前连接状态呈现**互斥且一致**的操作项：SHALL NOT 在同一状态下同时呈现互斥的「连接」与「断开」（已连接呈现「断开」，未连接呈现「连接」）。

#### Scenario: 移除机器需确认
- **WHEN** 用户对某 tab 触发「移除」
- **THEN** 系统 SHALL 先呈现二次确认
- **AND** 仅在用户确认后 SHALL 从 tab 栏与持久化列表删除该机器并断连；取消则 SHALL 不做任何更改

#### Scenario: 管理菜单连接项互斥一致
- **WHEN** 用户打开某 tab 的管理菜单
- **THEN** 已连接状态 SHALL 仅呈现「断开」、未连接状态 SHALL 仅呈现「连接」
- **AND** SHALL NOT 在同一状态下同时呈现「连接」与「断开」两项

### Requirement: 活动机器 tab 自动滚入可见区
机器 tab 栏 SHALL 在活动 session 变化时把活动 tab 自动滚入可见区（居中），使活动 tab 不停留在离屏位置。滚动 SHALL 事件驱动（随活动 session 变化触发），不得引入轮询或周期定时器。

#### Scenario: 切换到离屏 tab 自动滚入
- **WHEN** 活动 session 切换到当前不在可视范围的机器 tab
- **THEN** tab 栏自动滚动使该活动 tab 居中可见

#### Scenario: 自动滚动事件驱动
- **WHEN** 活动 tab 自动滚入
- **THEN** 仅由活动 session 变化事件触发，无轮询或周期定时器
### Requirement: 自动连接尊重用户主动断开意图

每个 Session SHALL 将用户连接意图与瞬时 ConnectionPhase 分开保存。用户显式 Disconnect 后，tab 切换、app 回前台、冷启动 bootstrap 和通用 shouldAutoConnect 判定 MUST NOT 自动连接该 Session；只有用户显式 Connect、重新配对或新增机器时才恢复自动连接意图。网络异常导致的 disconnected/failed 仍可按既有策略自动恢复。

#### Scenario: 主动断开后切 tab 不重连
- **WHEN** 用户断开机器 A，切到机器 B 后再切回 A
- **THEN** A 保持断开并显示可手动连接入口，不自动创建 transport

#### Scenario: 主动断开后回前台不重连
- **WHEN** 用户主动断开当前 Session 后使 app 后台再回前台
- **THEN** SessionsManager 不自动调用 connect

#### Scenario: 显式连接恢复自动意图
- **WHEN** 用户在主动断开状态点击 Connect
- **THEN** Session 恢复自动连接意图并开始连接，后续异常掉线仍走既有重连策略
