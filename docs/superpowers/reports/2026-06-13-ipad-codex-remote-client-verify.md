# 验证报告 — ipad-codex-remote-client

- 日期：2026-06-13
- 验证模式：**light**（规模评估=full[45 任务/6 能力/89 源文件]，但经用户授权走 light 代码侧验证；真机 E2E 标 follow-up 延期）
- 分支：feature/20260611/ipad-codex-remote-client（worktree 隔离）

## 轻量验证 5 项（新鲜证据）

| # | 检查项 | 结果 | 证据 |
|---|--------|------|------|
| 1 | tasks.md 全部勾选 | ✅ PASS | `grep -c '- [ ]'` = 0 |
| 2 | 改动与 tasks 一致 | ✅ PASS | `git diff --stat base-ref...HEAD` = 89 源文件 / +10509，覆盖 §1–12 任务 |
| 3 | 构建通过 | ✅ PASS | `xcodebuild build`（含于 test）exit 0 |
| 4 | 测试通过 | ✅ PASS | `xcodebuild test`：**97 通过 / 0 失败 / 1 跳过**（SpikeIntegration 需 SSH 凭证，XCTSkip）`** TEST SUCCEEDED **` |
| 5 | 无安全问题 | ✅ PASS | 无硬编码密钥/token；鉴权用 app 内生成 ed25519（CryptoKit）存 iOS Keychain；命中的 `password` case 为 SSHAuth 类型定义 + 测试 stub，非真实密钥 |

**结论：5 项全 PASS，无 CRITICAL。**

## 6 能力 delta spec 覆盖摘要（light 补充）

| 能力 | 实现 | 测试/验证 |
|------|------|-----------|
| mac-launcher | `scripts/start-codex-appserver.sh`（daemon bootstrap + sshd 校验 + 连接信息） | 实机手动验证（Task 2）；脚本逻辑 review |
| remote-connection | SSHClient + ProxyChannel + JSONRPCClient(多播) + ConnectionStore(状态机+重连) + 启动自动重连 | JSONRPCClient/ConnectionStore 单测；spike 握手；模拟器实连通过 |
| session-management | ProjectsStore(项目/对话启发式分区+折叠+徽标) + thread/list·resume·start + 左栏复刻 + 主界面布局 | ProjectsStore/SidebarCollapse/Orientation 单测；模拟器自检（分区/折叠/顶栏） |
| conversation-streaming | ThreadReducer(嵌套字段) + ConversationStore + ItemCards/ConversationView；批1 滞后根治(多播+订阅时机) / 批2 命令状态 / 批3 思考 | ThreadReducer/ConversationStore 单测（真实录制 fixture realTurnSequence.json）；3×全量绿 |
| approval-flow | ApprovalStore + ApprovalCoordinator(多播订阅) + ApprovalCardView（多选项 v2+legacy，超时/断线不自动批准） | ApprovalStore/ApprovalBoundary 单测 |
| appearance-locale | LocaleManager + ThemeManager + SettingsMenu（中英运行时切换 + 深浅主题） | LocaleManager/ThemeManager 单测；模拟器目视 |

## Follow-up（延期项，归档时一并记录）

- **§7 真机 E2E（7.1–7.4 / plan Task 20 Step 1–5）**：真机正式验收**延期为 follow-up**（用户确认）。模拟器(iPad-Test)功能场景（连接/发送/流式/恢复桌面会话）已验通过；真机特有项（后台行为、真实网络断连、审批闭环真机实操）待 iPad 回来后验收。
- 对话流命令状态/思考的**实时观感**为数据层单测覆盖；真机/模拟器发送消息的实时目视验收随真机 E2E 一并补。

## 备注
- 后续「5 窗口 UI 重设计」（摘要浮层 / 右栏多内容 / 下栏终端 / 顶栏重排）已决定**另开独立 change**，不在本 change 范围。
