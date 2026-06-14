# Proposal: 三列系统列布局重构（workspace-3col-layout）

## Why（问题背景）

`ipad-workspace-shell`（已交付）把右边栏做成**自绘 HStack 可拖列**（`PanelResizeHandle` + `@State` 宽度）。但拖动右栏把手时**严重闪屏**：中栏对话 ScrollView 随宽度每帧重排、右栏面板重绘。多次尝试均未根治（commit-on-release / 状态隔离到子视图 / 移除 `.transition`）——这是自绘横向 split 的固有问题。

对照印证：**左边栏是 `NavigationSplitView` 的系统列,拖动平滑不闪**;下边栏是自绘纵向拖,最跟手。差异在于右栏是"自绘横向 resize + body 重跑 + 内容重排"三者叠加。

## What（目标 + 范围）

把右边栏从自绘列改为**系统管理的列**(复用左栏同款机制),从根本上消除闪屏并统一三栏 resize 体验。

### 目标
- 右栏拖动**平滑不闪**(对照左栏体验)。
- 三栏 resize 机制统一(都走系统/平滑路径)。
- 既有能力零回归(摘要 overlay、橙主题、选中自渲染、把手高亮、Menu→popover、面板 toggle)。

### 方案要点
- **右栏 → `NavigationSplitView` 第三列(detail)**:三列布局(左 sidebar │ 中 content │ 右 detail),右列与 sidebar 同为系统 resize。
- **下栏 → 全宽 `.safeAreaInset(edge:.bottom)`** 挂在三栏 split 外层(像顶栏那样,不用 VStack 包裹以免破坏系统列拖动):横跨左+中+右全宽,把整个 split 往上压。
- **布局行为翻转**:由「下边栏不压左边栏」改为「**下边栏全宽、压所有(含左边栏)、最高优先级**」。

### 范围边界
- 仅改 `RootSplitView` 布局骨架(右栏 resize 机制、下栏位置与压缩行为)及其直接配套(把手/尺寸状态)。
- 保留并不回归:摘要悬浮浮层、橙 AccentColor 主题、左栏选中态自渲染、左把手宽度监听高亮、`SettingsMenu`/composer 模型选择的 `.popover`、顶栏 safeAreaInset 工具栏、各面板 toggle 与空态。

## Non-Goals（非目标）
- 右/下栏**真实内容**(Diff/文件/终端等)——各自后续 change。
- **sidebar 状态徽标**——下一个独立 change(可行性已调查)。
- 真机 E2E——follow-up(沿用 v1/change1 延期约定)。

## 关键未知 / 风险
- **iPad 上 `NavigationSplitView` 第三列(detail)是否用户可拖宽**——这是方案成立前提。构建早期必须先验证;若系统第三列不可拖,退方案(`.inspector` / 或保留自绘但换消闪手段),并暂停与用户确认。
- 三列 + 全宽 safeAreaInset 下栏 + 顶栏 safeAreaInset 的组合是否破坏列拖动——沿用 change1 教训(不 VStack 包裹 split)。
