## 1. 顶栏重排（workspace-layout）
- [x] 1.1 顶部固定全局工具栏按钮重排：左面板 · 下面板 · 右面板 · 摘要(`:≡`) · 设置（去前进/后退）
- [x] 1.2 inspector/摘要图标改用 Codex 真实 panel-right SVG（描边=关 / 填充=开）

## 2. 摘要悬浮浮层（workspace-layout / session-management）
- [x] 2.1 摘要从占列 inspector 改为 `:≡` 触发的悬浮浮层（内容自适应，非整列）
- [x] 2.2 摘要 P0 内容：diff 行数统计（turn/diff/updated 端侧算行）/ cwd / 进度(turn/plan/updated) / 任务(commandExecution 列表)
- [x] 2.3 空态（无内容时浮层占位）

## 3. 右边栏占位（workspace-layout）
- [x] 3.1 右边栏整列容器：toggle 显隐（右面板按钮）+ 空态占位
- [x] 3.2 右边栏可拖改宽 + 最小宽度

## 4. 下边栏占位（workspace-layout）
- [x] 4.1 下边栏底部容器：toggle 显隐（下面板按钮）+ 空态占位
- [x] 4.2 下边栏可拖改高 + 最小高度

## 5. 面板框架抽象
- [x] 5.1 抽象统一的"可显隐 + 空态 + 可拖 + 最小尺寸"面板容器，供右栏/下栏复用，后续 change 往里填内容

## 6. 验收
- [x] 6.1 模拟器自检：顶栏 5 按钮各自 toggle 对应面板显隐；摘要浮层显 P0 内容；右栏/下栏 空态+可拖+最小尺寸（快照逐态目视已核对 /tmp/workspace/*.png 对照 design §4；拖动手势离屏快照验不了，靠 UI 测试或用户确认）
- [ ] 6.2 真机验收（follow-up，沿用 v1 延期约定，本期延期）

## 7. 用户反馈精修（build 内增量）
- [x] 7.1 全局主题色：定义橙铜 AccentColor（深浅两态）+ ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME；List 选中强调由系统蓝改为主题橙（模拟器自检 /tmp/cropSel.png 已核对）
- [x] 7.2 选择性用橙：清理字面蓝（用户气泡→accentColor 淡底、composer 图片图标→中性）；次级控件(+/设置)中性、主操作(发送)用橙、顶栏 chrome 中性
- [x] 7.3 右栏拖动根因修复：`.inspector` 内建 resize 三栏全开时不可靠 → 改 HStack 自绘可拖列（DragGesture + WorkspaceMetrics.resizedRightWidth 纯函数单测）
- [x] 7.4 可拖提示：右栏左缘常驻把手（视觉提示可拖）+ 指针 hover 加粗高亮主题色（PanelResizeHandle，模拟器自检 /tmp/cropB_handle.png 已核对）

## 8. 用户反馈精修第二轮（build 内增量）
- [x] 8.1 #4 文件夹点击不折叠：SidebarCollapseStore 由 plain struct 改 @Observable class（内存 Set + UserDefaults 持久化），DisclosureGroup 绑定才触发重渲染
- [x] 8.2 #5 左栏收起再开选中橙色丢失：threadRow 选中态自渲染（橙底 listRowBackground + 橙标题），不依赖会丢失的系统 List 高亮（模拟器自检 /tmp/cropLeftMid 区域 + 选中框已核对）
- [x] 8.3 #3 把手 hover/拖动变橙：右栏 + 下栏把手统一 hovering||dragging 变橙加粗（触摸无 hover，靠「拖动中变橙」给反馈）
- [x] 8.4 #2 左栏可见把手：系统列右缘常驻装饰把手（allowsHitTesting=false 不拦截系统拖动；模拟器自检 /tmp/cropLeftMid.png 已核对）
- [x] 8.5 #1 右栏拖动闪屏：根因=横向 resize 每帧逼对话区重折行。改松手提交（拖动中只画跟手橙导引线，onEnded 才落 rightWidth），对齐左栏系统列行为
- [x] 8.6 #6 橙色清单已交付用户验收（选中行/用户气泡/发送键/把手 hover/待批准徽标+时钟/系统 accent 控件）

## 9. 用户反馈精修第三轮（build 内增量）
- [x] 9.1 #3 去掉右栏拖动的橙色导引实线
- [x] 9.2 #5 右栏实时重绘但不闪：根因实为「rightWidth @State 在 RootSplitView → 拖动每帧重渲染整个 NavigationSplitView」。抽出 WorkspaceDetailRegion 子视图，把 rightWidth/bottomHeight @State 关进去，拖动只重渲染该子树（对齐左栏系统列的实时重绘体验）
- [x] 9.3 #4 选中方框太丑：弃用 List(selection:) 系统方框，改自渲染（左缘橙条 + 橙标题 + 点按选择），模拟器自检 /tmp/verify3.png 已核对
- [x] 9.4 #1 左右把手对齐：下栏关闭时已对齐（/tmp/cropHandles2.png 核对）；下栏打开时右把手居中于被压短的上区故偏高（固有，见 design 说明）
- [x] 9.5 #9 sidebar 徽标可行性调查完成（结论：运行中/turn 完成·失败/等待输入 P0 纯协议可做；系统错误·item 失败 P1；token 进度 P2；未读蓝点需协议没有的 lastViewedAt → 拿不到）。建议独立 change 实现
<!-- 待决策（见对话）：#2 左把手拖动高亮 + #1 下栏开时也对齐 → 需把左栏从 NavigationSplitView 系统列换成自绘三栏（架构改，建议独立 change）；#7 模型菜单闪现 / #8 弹窗遮挡按钮 → Menu→popover 重构；#6 模拟器硬件键盘非 bug；#9 徽标 → 独立 change -->

