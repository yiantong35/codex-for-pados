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
- [x] 4.2 选中会话 `thread/resume` by threadId，加载并渲染历史
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

## 8. 外观与多语言（appearance-locale）
- [x] 8.1 本地化基础设施：String Catalog（zh+en）+ LocaleManager（@AppStorage 语言 + .environment(\.locale) 运行时切换）
- [x] 8.2 ThemeManager（@AppStorage 主题：system/light/dark + .preferredColorScheme），持久化
- [x] 8.3 把现有视图里硬编码中文串改为本地化 key（连接配置/三栏/对话/composer/审批卡/菜单）
- [x] 8.4 右上角全局设置按钮（齿轮）+ 菜单（语言切换 + 主题切换），接到主要界面
- [x] 8.5 单测：LocaleManager/ThemeManager 的选择持久化与默认值；编译 + 模拟器目视
- [x] 8.6 连接密钥生成复用：app 内生成一次 ed25519（CryptoKit）+ 自动复用 + 显示 OpenSSH 公钥/指纹（KeyManager + KeychainStore），替代 PEM 粘贴；SSHAuth 增 `.ed25519Key` 直传 Citadel；TDD（KeyManager 逻辑，内存 mock store）

## 9. 左栏复刻 v1（session-management 增量；plan Task 21–25）
- [x] 9.1 ThreadSummary 补 gitInfo（originUrl/branch）作为项目/对话分类信号（plan Task 21）
- [x] 9.2 ProjectsStore 启发式分类（项目/对话）+ 按 git/cwd 归组 + 排序 + isGrouped + 待批准计数（plan Task 22）
- [x] 9.3 SidebarCollapseStore 折叠状态本地持久化（plan Task 23）
- [x] 9.4 SidebarView 重构：项目区可折叠（DisclosureGroup）+ 对话区 + 待批准计数徽标（plan Task 24）
- [x] 9.5 RootSplitView 三栏 + InspectorView 环境信息简态（plan Task 25）

## 10. 主界面布局细化 v1.2（plan Task 26）
- [x] 10.1 inspector 可隐藏(默认收起)+顶部切换 + 设置齿轮移侧栏常显 + 默认聚焦侧栏(去大占位) + inspector 最小宽度更窄（plan Task 26）
- [x] 10.2 toolbar 目视修正：去重复侧栏开关(只留系统自动) + inspector 图标改 desktop 列表样式（commit a1d6900，模拟器自检通过）

## 11. 启动自动重连（remote-connection 增量）
- [x] 11.1 启动时若有已保存连接信息+密钥则自动连接一次，失败不循环（ConnectionConfigView 一次性 .task；模拟器自检：启动即自动连上主界面）
- [x] 11.2 inspector 图标改用 Codex 真实 SVG(panel-right 描边/填充) + 空态可拖修复（commit 15d8741；顶栏固定方案 a2a20f7）

## 12. 对话流滞后修复 + 状态提示（conversation-streaming 增量；调查报告确证）
- [x] 12.1 批1·滞后 bug：notifications() 改多播(三消费者不再抢占) + ThreadReducer 改读嵌套字段(turn.id/item.*) + 录真实通知 fixture 重写测试（CRITICAL）
- [x] 12.1a 修多播订阅注册竞态(startObserving 改 async 先注册再消费), 消除 testStreamingDeltaUpdatesState 间歇失败
- [x] 12.2 批2·命令状态：ConversationItem.commandExecution 加 status/exitCode/durationMs + reducer 落值 + ItemCard 渲染 + "已运行 N 条命令" 汇总
- [ ] 12.3 批3·思考提示：新增 reasoning case + 3 个 reasoning 通知常量 + 归约 + "正在思考" 卡片
