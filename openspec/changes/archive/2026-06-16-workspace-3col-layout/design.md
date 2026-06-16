# Design（高层）: 三列系统列布局重构

> 高层架构决策。深度技术设计 + 风险/测试细节由 comet-design 阶段的 Design Doc 承接。

## 架构决策

### A1：右栏 = `.inspector` 系统检视列
现状 `NavigationSplitView { sidebar } detail: { HStack{中栏 | 自绘把手 | 右栏} }` →
改为 `NavigationSplitView { sidebar } detail: { 中栏对话.inspector(isPresented:$showRightPanel){ RightPanelView } }`。
- inspector 是 SwiftUI 给「右侧」的系统列（左 sidebar 的镜像）：系统托管 resize（平滑不闪）+ 可显隐 + 最小宽。
- 为何不用 NavigationSplitView detail 第三列：detail 列不能显隐（columnVisibility 只控左侧列），右栏要 toggle → 用 inspector。
- 宽度：`.inspectorColumnWidth(min:ideal:max:)`（沿用 WorkspaceMetrics 常量）。显隐：`showRightPanel` 绑 `isPresented`。
- 去掉 `PanelResizeHandle`(右用法)/`rightWidth @State`/`WorkspaceDetailRegion` 右栏自绘逻辑。
- **关键：不 VStack 包 detail**（旧 inspector 拖不动的根因）。下栏改全宽外层 safeAreaInset（A2）后，inspector 不被包裹 → 拖动恢复 + 系统托管不闪。
- **前提验证（构建第一步 spike）**：不被 VStack 包的 inspector，三栏全开时拖动是否正常+不闪。异常 → 暂停议退路。

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
