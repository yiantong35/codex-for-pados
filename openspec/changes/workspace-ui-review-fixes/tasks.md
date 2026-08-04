## 1. 批1 — P1 发布阻断项

- [x] 1.1 D1 侧聊状态隔离：`ConversationView` 增 `bindsWorkspaceState`（默认 true），五处写点（state onChange / fetchFullDiff / startReview / onDisappear 清空 / setResumeHandler 归属）统一 gate；`SideChatView.swift:72` 挂载传 false
- [x] 1.2 D1 单测：侧聊实例（bindsWorkspaceState=false）对 `ActiveConversationHolder` 零写入；主对话实例正常写入；侧聊开/关不清空主对话 state/fetchFullDiff/startReview
- [x] 1.3 D2 `ConnectionStore` resumeHandler 单一属性 → token 订阅表；`addResumeHandler`(返回 token，保留首连恰一次补触发，订阅者维度化 `didInitialRejoin`) / `removeResumeHandler(token)`；物理重连 `.ready` 遍历触发全部
- [x] 1.4 D2 迁移调用点：`ConversationView` `.task` 用 add→（onDisappear/defer）remove 配对；`setResumeHandler` 保留为薄封装或全量迁移
- [x] 1.5 D2 单测：多订阅者互不覆盖；首连对已 ready 的新订阅者补触发恰一次；重连遍历触发全部；注销后不再触发
- [x] 1.6 D3 `RightPanelContainerView` tab 条去每标签 `maxWidth:.infinity` 独占，改等分压缩 + 极窄降级（图标/横向滚动）；尾部全屏入口不挤占 tab 命中区
- [x] 1.7 D3+D9 测试：断言三 tab（review/files/sideChat）在 320pt 宽下全部可见且可命中；升级 `OrientationSnapshotTests:254` 由「PNG 非空」为结构断言

## 2. 批2 — P2

- [x] 2.1 D4 `WorkspaceMetrics` 增「三栏全开最低宽」常量 + 降级决策纯函数（容器宽 → 显示哪些栏）；`ResizableColumns` 容器 <阈值时自动收起右栏（再不够收左栏），渲染宽度之和 ≤ 容器、中栏永远完整、列宽持久化保留
- [x] 2.2 D4 单测：<668pt 时降级函数不产生溢出布局；恢复宽度后可再展开；竖屏/Stage Manager 窄窗各验一遍不横向溢出
- [x] 2.3 D5 探明项目现有「跟随注入 locale」本地化通道（Open Question）；FileBrowserView/ReviewPanelTypes/ShortcutsSettingsSectionView 等硬编码中文 + 动态标签（右栏 tab label、审查模式名）改为跟随注入 locale；xcstrings 补键
- [x] 2.4 D5 测试：注入英文 locale 时上述文案为英文、无中英混排
- [x] 2.5 D6 `TabBarView` 移除机器加 `confirmationDialog`（destructive）二次确认；管理菜单连接/断开按连接态互斥（XOR）
- [ ] 2.6 D7 图标按钮（ComposerView 图片/模型/停止/发送等）统一 ≥44pt 命中框 + `.accessibilityLabel`；`SidebarView` 会话行 `onTapGesture` 改 `Button`（button trait + 键盘激活），保留视觉
- [ ] 2.7 D7 测试/验收：VoiceOver 语义标签存在；命中框 ≥44pt；会话行键盘可激活

## 3. 批3 — P3 + 收口

- [ ] 3.1 D8 `RootSplitView` detail 未选会话渲染 `split.selectConversation` 引导空态
- [ ] 3.2 D8 `ConversationView` 滚动位置感知：`ScrollViewReader` + 近底判定，仅近底自动滚，否则显「新消息」浮标点按到底；无新增轮询/定时器
- [ ] 3.3 D8 单测：近底时新消息自动滚；远离底部时不自动滚且出现「新消息」入口
- [ ] 3.4 D9 收口检查：所有新增/改动路径有断言级测试；无仅「PNG 非空」的空快照断言残留

## 4. 验证

- [ ] 4.1 iOS 完整 `xcodebuild test` 全绿（含新增单测）
- [ ] 4.2 UI 三基线（`ui-adaptation-baseline`）：横屏/竖屏 + 手势/软键盘/外接键盘 逐项覆盖碰 UI 的改动
- [ ] 4.3 能耗（`energy-awareness-principle`）：确认滚动感知/降级无新增常驻轮询/定时器
- [ ] 4.4 模拟器自验收（`self-verify-on-simulator`）：8 项发现逐条复现→修复对照
- [ ] 4.5 真机验收清单沉淀到 `docs/真机验收清单.md`（VoiceOver/指针/真实分屏 受设备配额限制的项）
