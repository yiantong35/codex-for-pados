# Design（高层）: 三列系统列布局重构

> 高层架构决策。深度技术设计 + 风险/测试细节由 comet-design 阶段的 Design Doc 承接。

## 架构决策

### A1：三列 NavigationSplitView（右栏 = 系统第三列）
现状 `NavigationSplitView { sidebar } detail: { HStack{中栏 | 自绘把手 | 右栏} }` →
改为 `NavigationSplitView { sidebar } content: { 中栏对话 } detail: { 右栏 }`（三列）。
- 右列(detail)与 sidebar 同为系统管理列 → 系统 resize，平滑不闪。
- 去掉 `PanelResizeHandle`/`rightWidth @State`/`WorkspaceDetailRegion` 的右栏自绘逻辑。
- 右栏显隐：用 `columnVisibility`（`NavigationSplitViewVisibility`）控制 detail 列显隐（替代 `showRightPanel` 的 HStack 条件）。
- **前提验证（构建第一步）**：iPad 上 detail 列是否用户可拖宽。若不可拖 → 退方案，暂停确认。

### A2：下栏 = 全宽 safeAreaInset(.bottom)
下栏从「detail 区内 VStack 分割（压中+右）」改为「整个 split 外层 `.safeAreaInset(edge:.bottom)`」：
- 全宽横跨左+中+右，把整个三栏 split 往上压（**布局翻转：压所有，含左栏**）。
- 不用 VStack 包裹 split（沿用 change1 教训，避免破坏系统列拖动）；与顶栏 `.safeAreaInset(.top)` 对称。
- 下栏仍自绘纵向拖把手（`BottomPanelView`，最跟手），保留 hover/拖动变橙。

### A3：保留项（不回归）
- 顶栏 `.safeAreaInset(.top)` 工具栏（左/下/摘要/右/设置）；右面板按钮改为切 `columnVisibility` 的 detail 显隐。
- 摘要 `.overlay` 常驻浮层 + P0 数据。
- 橙 `AccentColor` 主题、左栏选中态自渲染、左把手宽度监听高亮。
- `SettingsMenu` + composer 模型选择 `.popover`。
- 右/下栏空态占位 + 最小尺寸。

### A4：图标与 toggle
- 右面板按钮 toggle detail 列显隐；下面板按钮 toggle 全宽下栏显隐；其余不变。

## 数据流
纯 UI 布局层，无新增协议/数据流。右栏宽度由系统列托管（不再 `@State`）；下栏高度仍 `@State`（`bottomHeight` + clamp）。

## 测试策略（高层）
- 单测：下栏高度 clamp（已有 `WorkspaceMetrics`）；摘要派生逻辑（已有，不回归）。
- 模拟器逐态自检（截图）：三列同屏、下栏全宽覆盖左右、各面板空态/显隐、主题/选中不回归。
- 拖动平滑/手势：CLI 验不了 → 用户真机/模拟器确认（右栏是否还闪、下栏拖高、detail 列可否拖宽）。
