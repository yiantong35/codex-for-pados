# Agent 交接文档 — iPad CodexRemote

> 给接手的 agent。读完这份就能在新开发机上无缝续上。最后更新：2026-06-15。
> 输出语言：中文。

---

## 0. TL;DR（30 秒上手）

- **项目**：iPad SwiftUI app，通过 **SSH + `codex app-server proxy`**（JSON-RPC over stdio）远程控制 Mac 上的 Codex，复刻 Codex desktop 体验。
- **流程**：全程走 **Comet 工作流**（OpenSpec 管 WHAT + Superpowers 管 HOW；阶段 open→design→build→verify→archive；`.comet.yaml` 状态 + guard 脚本）。**不要绕过 comet 直接写代码。**
- **现在在哪**：v1 + change1 已归档合并；**change2 `workspace-3col-layout` 在 build 阶段、就差最后一步**（用户实测验收）。
- **下一步**：新机装好环境 → 跑 `/comet` → 自动检测到 change2(build) → 从 **tasks 5.3「用户实测」**续上 → verify → archive → 再开最后一个 change（sidebar 徽标）。
- **关键约束**：① CLI 截图只能验静态，**拖动/hover/手势/键盘必须让用户实测**；② 改完 UI **先自己在 iPad-Test 模拟器截图自检再报用户**；③ comet 决策点必须停下等用户明确选择；④ **PR 直接处理（建/推/合）不用每次问**（账号 yiantong35）。

---

## 1. 仓库 / 分支 / 技术栈

- 远程：`https://github.com/yiantong35/codex-for-pados.git`（账号 yiantong35）。
- 分支（3 个，本地+origin 均有）：
  - `master` — 主干（v1 经 PR #1、change1 经 PR #2 已合入）。
  - `feature/20260611/ipad-codex-remote-client` — v1（已合，保留）。
  - **`worktree-ipad-workspace-shell`** — 当前工作分支，含 change1(已合) + **change2 进行中**。已全推 origin。
- 技术栈：SwiftUI（iOS 17+，deploymentTarget 17.0）、XCTest、SPM 依赖 **Citadel**（SSH 库）。工程用 **xcodegen** 从 `ios/project.yml` 生成 `ios/CodexRemote.xcodeproj`（pbxproj 已跟踪；增删 `.swift` 后跑 `xcodegen generate`）。
- bundle id：`com.tangyujie.codexremote`。

---

## 2. 新开发机环境搭建

仓库里没有、**必须另装**：
1. **Xcode**（iOS 17+ SDK）+ `xcode-select --install`。
2. `brew install xcodegen`（可选 `brew install gh` 处理 PR）。
3. **名为 `iPad-Test` 的 iPad 模拟器**（构建/验证脚本硬编码 `name=iPad-Test`）。
4. **Comet + Superpowers skill 包装到 `~/.claude/skills/`**（不在仓库里，不装 `/comet` 跑不了）。
5. （可选）拷 Claude 项目记忆 `~/.claude/projects/-Volumes-mount-codex-for-pados/memory/`（含完整进度）。

拉代码（**clone，别 zip**——worktree 靠绝对路径链接、zip 换机会断；`ios/DerivedData` 别带）：
```bash
git clone https://github.com/yiantong35/codex-for-pados.git
cd codex-for-pados
git checkout worktree-ipad-workspace-shell   # change2 全部在这
cd ios && xcodegen generate                  # 首次 build 自动拉 Citadel(需联网)
```

构建 / 测试（统一这条；脚本同义见 `scripts/comet-build-check.sh` / `comet-verify-check.sh`）：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData -project ios/CodexRemote.xcodeproj
# 预期末尾 ** TEST SUCCEEDED **（当前 121 测试 / 0 失败）
```
模拟器自检截图：`xcrun simctl install/launch iPad-Test …` + `xcrun simctl io iPad-Test screenshot /tmp/x.png`，再用 Read 看图。**注意：截图只能验静态布局/颜色；拖动手感/不闪/hover/键盘弹出 CLI 验不了，必须用户实测。**

---

## 3. 进度全景

| 阶段 | change | 状态 |
|------|--------|------|
| v1 | `ipad-codex-remote-client` | ✅ 归档（archive/2026-06-13-…）+ PR #1。连接/会话/左栏/对话流/审批/外观/三栏/图标。 |
| v2-1 | `ipad-workspace-shell`（5 窗口骨架） | ✅ 归档（archive/2026-06-14-…）+ PR #2。五窗口骨架+顶栏重排+摘要 overlay+橙主题+选中自渲染+把手+Menu→popover。 |
| v2-2 | **`workspace-3col-layout`（三列重构）** | 🔨 **build 中（未归档）——见 §4** |
| v2-3 | sidebar 状态徽标 | 📋 待开（调查已完成，见 §6） |

---

## 4. change2 `workspace-3col-layout` —— 恢复指引（最重要）

**目标**：把 change1 里自绘横向 resize 的右栏（拖动**闪屏**）换成系统托管列消闪；下栏改全宽。

**最终方案（用户已拍板 A）**：
- **右栏 = `.inspector(isPresented:$showRightPanel)` + `.inspectorColumnWidth(min/ideal/max)`**。inspector 是 SwiftUI 给右侧的系统检视列（左 sidebar 的镜像），系统托管 resize → 不闪、可显隐、可拖。
  - 为何不用 NavigationSplitView 的 detail 第三列：**detail 列不能显隐**（columnVisibility 只控左侧列），右栏要 toggle → 只能用 inspector。
- **下栏 = split 外层全宽 `.safeAreaInset(edge:.bottom)`**（压缩上推、覆盖左+中+右；`.move` 滑入动画）。**布局翻转**：由「下栏不压左栏」改为「下栏压所有」。
- 删了自绘 `WorkspaceDetailRegion` 右栏 / `WorkspaceMetrics.resizedRightWidth` / 整个 `PanelResizeHandle.swift`。
- 右栏左缘加了装饰把手（宽度监听拖动变橙，像左栏）。

**已完成**：Task 1–5（commit `e47534b`），121 测试 0 失败。tasks.md 已勾到 5.2。
**剩余**：
- `tasks 5.3` **用户实测确认**（右栏拖动平滑不闪 / 下栏拖高跟手 / inspector 可拖）—— **这是当前唯一待办**。
- `tasks 5.4` 真机验收（follow-up 延期，沿用 v1 约定）。

**已接受的取舍**（别再当 bug 改）：inspector「**左栏拖动会挤右栏**」——系统空间分配所致，用户接受（换"不闪"）。

**怎么恢复**：
```bash
/comet            # 自动检测到 active change workspace-3col-layout(build)
```
→ 装最新构建让用户实测 5.3 → 用户 OK 后：勾 plan 全部步骤 + tasks 5.3 → `comet-guard workspace-3col-layout build --apply` → `/comet-verify`（full）→ `/comet-archive`（归档前等用户确认）→ PR 处理。
- `.comet.yaml`：phase=build / build_mode=executing-plans / tdd=direct / isolation=worktree / build_command,verify_command 已配 `scripts/comet-*-check.sh`。
- 设计依据：`docs/superpowers/specs/2026-06-14-workspace-3col-layout-design.md`；计划：`docs/superpowers/plans/2026-06-14-workspace-3col-layout.md`（头部有迁移状态 note）。

---

## 5. 硬经验 / 必避的坑（前面踩过）

- **自绘横向 resize 会闪屏**：用 `@State` 改宽，拖动时每帧重渲染整树（含中栏对话 ScrollView 重排）→ 闪。**系统列（sidebar / inspector）系统托管 resize 不闪**。结论：右栏用 inspector，别再自绘横向拖。
- **VStack 包 split / detail 会破坏拖动**：v1/早期把 detail 用 `VStack{中栏.inspector ; 下栏}` 包起来 → inspector 拖不动。**顶栏、下栏都用 `.safeAreaInset` 挂在 split 外层，绝不 VStack 包 split。**
- **NavigationSplitView 左右不对称**：左 sidebar 列可显隐+可拖；右侧 detail 第三列**不能显隐**。右侧要"可显隐+可拖+不闪"只能用 `.inspector`。
- **系统列拖动事件钩不到**：要给系统列（左 sidebar / 右 inspector）做"拖动中把手变橙"，用 `GeometryReader` **监听宽度变化**来点亮（不能直接监听拖动手势）。
- **全局主题色**：已定义橙铜 `AccentColor`（深浅两态）+ `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`。**选择性用橙**：选中/主操作/链接用橙；顶栏 chrome、次级按钮用中性。别再引入系统蓝。
- **图标**：摘要按钮 = `list.bullet`（不是 panel-right SVG，那是 inspector 图标，曾误用）。
- **Menu 弹窗遮挡按钮**：用 `.popover(isPresented:)` + `.presentationCompactAdaptation(.popover)` 替代 `Menu`（SettingsMenu、composer 模型选择已改）。
- **模拟器键盘**：点输入框不弹键盘 = 连了 Mac 硬件键盘，**Cmd+K** 切换，**不是 bug**。
- **CLI 验证边界**：截图只能看静态；拖动/hover/手势/键盘 → 用户实测或 XCUITest。
- **改完 UI 先模拟器自检截图**（必要时裁剪放大看图标/对齐）**再报用户**。

---

## 6. 最后一个 change（待开）：sidebar 状态徽标

调查已完成（Codex 在项目/会话、收起/展开下有不同徽标）。可行性结论：
- **P0（纯 app-server 可做）**：运行中 spinner（`turn/started`→activeTurnId）、turn 完成/失败圆点（`turn/completed` 的 turn.status）、等待输入（`thread/status/changed` 的 activeFlags `waitingOnUserInput`）。已有：待批准（橙徽标）。
- **P1**：系统错误（ThreadStatus.systemError / turn.error）、item 失败计数。
- **P2**：token 用量（`thread/tokenUsage/updated`，需推导）。
- **❌ 拿不到**：**未读蓝点**（协议无 "lastViewedAt"，用户图里那个蓝点）；浏览器（Electron webview）；git/gh/PR 状态（desktop 本地）。
- 实现：扩 `ConversationState`（lastTurnStatus/activeFlags 等）+ `ThreadReducer` 消费 `thread/status/changed`·`turn/completed`·`thread/tokenUsage/updated` + `SidebarView` 渲染徽标（项目行收起时聚合）。

---

## 7. 用户偏好（standing，务必遵守）

- **PR 直接处理**（创建/推送/合并），不必每次问（账号 yiantong35，remote 见 §1）。
- **改完 UI 先自己在 iPad-Test 模拟器验收、截图自查，确认没问题再报用户。**
- **comet 决策点必须停下**用结构化提问等用户明确选择（plan-ready、隔离/执行/TDD、verify 失败处理、分支处理、归档前确认、范围扩张拆分等）——不得用默认值/历史偏好替代。
- 默认**中文**输出。
- 不硬编码密钥；SSH 用 Keychain 里的 ed25519（app 每次安装自生成，换模拟器/机器要在 Codex 主机重新授权公钥）。

---

## 8. 关键协议事实（app-server v2，给后续 change）

- 双通道：**v2 app-server**（iPad 经 SSH 能拿：turn/diff、turn/plan、thread/status、tokenUsage、command/fs、Thread.cwd、gitInfo…）+ **desktop 本地服务**（git/gh/浏览器，iPad 拿不到）。
- 右边栏后续 tab 可行性：Diff ✅P0、文件(fs/*) P1、终端(command/exec) P1、编辑器/预览 P2、**浏览器❌**（可退而用 WKWebView）。
- 实际连接测试要一台跑 `codex app-server` 的 Mac，SSH 可达（`scripts/start-codex-appserver.sh`）。

---

## 9. 立即要做的第一件事

新机装好环境后，**装最新构建到 iPad-Test，让用户实测 change2 的 tasks 5.3**（右栏 inspector 拖动是否平滑不闪、下栏拖高是否跟手、inspector 是否可拖）。用户确认 OK → 收尾 change2（勾 plan → guard → verify → archive）→ 开 change3（徽标）。
