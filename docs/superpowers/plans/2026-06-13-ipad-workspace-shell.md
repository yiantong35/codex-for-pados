---
change: ipad-workspace-shell
design-doc: docs/superpowers/specs/2026-06-13-ipad-workspace-shell-design.md
base-ref: d8088a7cd45d2d0df07dc8af16d44ac2c122f113
---

# iPad CodexRemote 五窗口工作区骨架 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iPad 主界面从 v1「固定顶栏 + 三栏 + 占列 inspector」升级为复刻 Codex desktop 的五窗口工作区骨架（左边栏 · 中间 · 右边栏整列 · 下边栏 · 摘要悬浮浮层），右/下栏本期只做占位（空态 + 可拖 + 最小尺寸 + toggle）。

**Architecture:** 顶栏继续用 `.safeAreaInset(edge:.top)` 挂在 `NavigationSplitView` 上（不用 VStack 包整个 split，避免破坏 inspector 拖动）。左边栏 = split 的 sidebar 列（满高）；detail 区改为一个 `VStack { 上半(中间 + 右栏 `.inspector`) ; 可拖 Divider ; 下栏 }`，使下栏只压短「中间 + 右栏」、不伸到左边栏。摘要从 v1 占列 inspector 改为 `:≡` 按钮触发的 `.popover`。摘要 P0 数据从 `ConversationState`（diff 行数 / 命令任务）+ `ThreadSummary`（cwd）+ 新增的 plan 模型（`turn/plan/updated`）派生，派生逻辑抽成纯函数单测。

**Tech Stack:** Swift / SwiftUI（iPadOS）、`NavigationSplitView` + `.inspector` + `.popover` + `.safeAreaInset`、XCTest（纯逻辑单测 + `OrientationSnapshotTests` 快照工具）、`Localizable.xcstrings`、Codex 真实 SVG 资产（`InspectorClosed`/`InspectorOpen`）。

**设计文档：** `docs/superpowers/specs/2026-06-13-ipad-workspace-shell-design.md`（HOW）；规范事实源为 OpenSpec delta spec（`openspec/changes/ipad-workspace-shell/specs/workspace-layout/spec.md` 与 `specs/session-management/spec.md`）。

**测试命令约定（全程统一）：**
- 单测（在 `ios/` 目录下执行）：
  ```bash
  xcodebuild test -scheme CodexRemote \
    -destination 'platform=iOS Simulator,name=iPad-Test' \
    -derivedDataPath DerivedData \
    -only-testing:CodexRemoteTests/<测试类>/<测试方法>
  ```
- 纯逻辑（diff 行数、plan 归约、最小尺寸 clamp、toggle 状态）：走严格 TDD 单测（先红后绿）。
- 布局 / 面板显隐 / 空态：用既有 `OrientationSnapshotTests` 快照写法（`UIHostingController` + window + `layer.render` → PNG 落 `/tmp/...`），断言落在「新增本地化键可解析」+「PNG 非空」等可判定信号上，人工目视截图复核。
- **拖动手势**：CLI 离屏快照验不了（见 `OrientationSnapshotTests` 注释「drawHierarchy 离屏恒空白」「拖动靠 UI 测试或用户确认」）；本计划对宽/高调节只单测纯 clamp 逻辑 + 在代码里接好原生/手势，拖动效果由 UI 测试或用户在模拟器确认。

---

## 文件结构（决策锁定）

**新建（生产代码）：**
- `ios/CodexRemote/Domain/TurnPlan.swift` — `TurnPlanStepStatus` 枚举 + `TurnPlanStep` 结构（plan 步骤模型，对应 `turn/plan/updated`）。
- `ios/CodexRemote/Domain/WorkspaceSummary.swift` — 摘要 P0 派生纯函数集合（`diffLineCounts` / `planProgress` / `commandTasks`），无 SwiftUI 依赖，便于单测。
- `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift` — 面板最小尺寸常量 + `clampPanelSize` 纯函数（右栏最小宽 / 下栏最小高）。
- `ios/CodexRemote/Views/Workspace/PanelEmptyState.swift` — 共享空态视图（右栏 / 下栏复用）。
- `ios/CodexRemote/Views/Workspace/RightPanelView.swift` — 右边栏占位（空态包装，本期无真实内容）。
- `ios/CodexRemote/Views/Workspace/BottomPanelView.swift` — 下边栏占位（空态 + 顶部可拖 Divider 容器）。
- `ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift` — 摘要悬浮浮层内容视图（消费 `WorkspaceSummary` 派生数据 + 空态）。

**修改（生产代码）：**
- `ios/CodexRemote/Protocol/Methods.swift` — 在 `ServerNotificationMethod` 增 `turnPlanUpdated = "turn/plan/updated"`。
- `ios/CodexRemote/Domain/ConversationModels.swift` — `ConversationState` 增 `plan: [TurnPlanStep]` 字段。
- `ios/CodexRemote/Domain/ThreadReducer.swift` — `apply(_:to:)` 增 `turn/plan/updated` 归约分支。
- `ios/CodexRemote/Views/RootSplitView.swift` — 顶栏 5 按钮重排 + detail 区改 VStack（中间+右栏 / 可拖 Divider / 下栏）+ 摘要改 popover + 接线右/下栏 toggle。
- `ios/CodexRemote/Resources/Localizable.xcstrings` — 新增本地化键（顶栏按钮辅助标签、面板空态、摘要标题/字段/空态）。

**修改（测试）：**
- `ios/CodexRemoteTests/ThreadReducerTests.swift` — 增 plan 归约测试。
- `ios/CodexRemoteTests/OrientationSnapshotTests.swift` — 增工作区布局 / 面板空态 / 摘要浮层快照。
- 新建 `ios/CodexRemoteTests/WorkspaceSummaryTests.swift` — 摘要 P0 派生纯函数单测。
- 新建 `ios/CodexRemoteTests/WorkspaceMetricsTests.swift` — 最小尺寸 clamp 单测。

**Xcode target 成员**：本仓库用 `.xcodeproj`，新建 `.swift` 文件需加入对应 target（生产文件→`CodexRemote`，测试文件→`CodexRemoteTests`）。若新文件未被编译（`xcodebuild` 报 "cannot find type in scope"），先把文件加入 target 的 `Sources` build phase（见 Task 0）。

---

## Task 0: 确认基线可编译可测

**Files:** 无改动（仅验证环境）

- [x] **Step 1: 在基线跑一个已存在的单测，确认工具链 + 模拟器名可用**

Run（在 `ios/` 目录）：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/ThreadReducerTests/testTurnStartedMarksRunning
```
Expected: `TEST SUCCEEDED`。若报模拟器不存在，按 `docs/superpowers/plans/README-dev-setup.md` 创建名为 `iPad-Test` 的模拟器后重试。

- [x] **Step 2: 记录基线 commit**

Run：`git rev-parse HEAD`
Expected: 输出当前 HEAD（应为基线 `d8088a7...` 或其后的 build 起点）。不提交。

---

## Task 1: 新增 plan 步骤模型（`turn/plan/updated` 的数据载体）

**Files:**
- Create: `ios/CodexRemote/Domain/TurnPlan.swift`
- Test: `ios/CodexRemoteTests/WorkspaceSummaryTests.swift`（本任务先建文件放第一个测试）

> 背景：摘要 P0「进度」来自 `turn/plan/updated`，但当前代码库无任何 plan 模型（`grep TurnPlan` 为空）。先建模型，下一任务接 reducer。状态枚举对齐 design D2：pending / inProgress / completed。

- [x] **Step 1: 写失败测试**

新建 `ios/CodexRemoteTests/WorkspaceSummaryTests.swift`：
```swift
import XCTest
@testable import CodexRemote

final class WorkspaceSummaryTests: XCTestCase {
    func testTurnPlanStepStatusFromRawString() {
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "in_progress"), .inProgress)
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "completed"), .completed)
        // 未知 / 缺省 → pending（容错，避免崩溃）
        XCTAssertEqual(TurnPlanStepStatus.from(any: nil), .pending)
        XCTAssertEqual(TurnPlanStepStatus.from(any: "bogus"), .pending)
    }

    func testTurnPlanStepEquatable() {
        let a = TurnPlanStep(step: "写测试", status: .inProgress)
        let b = TurnPlanStep(step: "写测试", status: .inProgress)
        XCTAssertEqual(a, b)
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests
```
Expected: 编译失败 / FAIL，错误类似 "cannot find 'TurnPlanStepStatus' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Domain/TurnPlan.swift`：
```swift
import Foundation

/// plan 步骤状态（对齐 codex turn/plan/updated 的 step.status）。
/// 真实取值含下划线形态 "in_progress"，另兼容驼峰 "inProgress" 容错。
enum TurnPlanStepStatus: String, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed

    /// 从任意 JSON 值容错解析；缺省 / 未知 → pending（不崩溃）。
    static func from(any: Any?) -> TurnPlanStepStatus {
        guard let s = any as? String else { return .pending }
        switch s {
        case "pending": return .pending
        case "in_progress", "inProgress": return .inProgress
        case "completed", "complete": return .completed
        default: return .pending
        }
    }
}

/// 单条 plan 步骤（摘要「进度」P0 数据）。
struct TurnPlanStep: Equatable {
    var step: String
    var status: TurnPlanStepStatus
}
```

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests
```
Expected: `TEST SUCCEEDED`（若报找不到类型，把两个新文件加入对应 target 后重跑——见 Task 0 "Xcode target 成员"）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Domain/TurnPlan.swift ios/CodexRemoteTests/WorkspaceSummaryTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): add TurnPlanStep model for summary progress"
```

---

## Task 2: ConversationState 持有 plan + reducer 归约 `turn/plan/updated`

**Files:**
- Modify: `ios/CodexRemote/Protocol/Methods.swift:33`（`ServerNotificationMethod` 内增一行）
- Modify: `ios/CodexRemote/Domain/ConversationModels.swift:36`（`ConversationState` 增字段）
- Modify: `ios/CodexRemote/Domain/ThreadReducer.swift:68`（`apply` 增分支）
- Test: `ios/CodexRemoteTests/ThreadReducerTests.swift`

> 真实 `turn/plan/updated` 形状未在仓库样本中固化；按 codex plan tool 惯例，plan 在 `params.plan`（数组），每项 `{step, status}`。归约用容错读取（缺字段不崩溃），与现有 reducer 风格一致。

- [x] **Step 1: 写失败测试**

在 `ios/CodexRemoteTests/ThreadReducerTests.swift` 的 class 内新增（放在其它 `func test...` 之间）：
```swift
    func testTurnPlanUpdatedPopulatesPlan() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/plan/updated", ["plan": [
            ["step": "读代码", "status": "completed"],
            ["step": "写测试", "status": "in_progress"],
            ["step": "实现", "status": "pending"],
        ]]), to: &state)
        XCTAssertEqual(state.plan, [
            TurnPlanStep(step: "读代码", status: .completed),
            TurnPlanStep(step: "写测试", status: .inProgress),
            TurnPlanStep(step: "实现", status: .pending),
        ])
    }

    func testTurnPlanUpdatedReplacesPreviousPlan() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/plan/updated", ["plan": [["step": "旧", "status": "pending"]]]), to: &state)
        reducer.apply(notif("turn/plan/updated", ["plan": [["step": "新", "status": "completed"]]]), to: &state)
        // plan 是整体快照，后到的覆盖先到的（不累加）
        XCTAssertEqual(state.plan, [TurnPlanStep(step: "新", status: .completed)])
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/ThreadReducerTests/testTurnPlanUpdatedPopulatesPlan
```
Expected: 编译失败 / FAIL，错误类似 "value of type 'ConversationState' has no member 'plan'"。

- [x] **Step 3: 写最小实现（三处）**

3a. `ios/CodexRemote/Protocol/Methods.swift` —— 在 `static let turnDiffUpdated = "turn/diff/updated"` 下一行加：
```swift
    static let turnPlanUpdated = "turn/plan/updated"
```

3b. `ios/CodexRemote/Domain/ConversationModels.swift` —— 在 `ConversationState` 的 `var activeTurnKind` 之后加字段：
```swift
    /// 当前 turn 的 plan 步骤（来自 turn/plan/updated，整体快照）。摘要「进度」P0 数据源。
    var plan: [TurnPlanStep] = []
```

3c. `ios/CodexRemote/Domain/ThreadReducer.swift` —— 在 `case ServerNotificationMethod.fileChangePatchUpdated, ServerNotificationMethod.turnDiffUpdated:` 分支之后、`case ServerNotificationMethod.itemCompleted:` 之前插入：
```swift
        case ServerNotificationMethod.turnPlanUpdated:
            // plan 是整体快照：每次用最新数组替换（缺字段容错，step 缺省空串、status 缺省 pending）。
            let raw = p["plan"] as? [[String: Any]] ?? []
            state.plan = raw.map { entry in
                TurnPlanStep(step: entry["step"] as? String ?? "",
                             status: TurnPlanStepStatus.from(any: entry["status"]))
            }
```

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/ThreadReducerTests
```
Expected: `TEST SUCCEEDED`（新增两个 plan 测试 + 既有 reducer 测试全绿）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Protocol/Methods.swift ios/CodexRemote/Domain/ConversationModels.swift ios/CodexRemote/Domain/ThreadReducer.swift ios/CodexRemoteTests/ThreadReducerTests.swift
git commit -m "feat(workspace): reduce turn/plan/updated into ConversationState.plan"
```

---

## Task 3: 摘要 P0 派生纯函数 —— diff 行数统计

**Files:**
- Create: `ios/CodexRemote/Domain/WorkspaceSummary.swift`
- Test: `ios/CodexRemoteTests/WorkspaceSummaryTests.swift`（追加）

> diff 行数来源：`ConversationState.items` 里的 `.fileChange(id, file, added, removed, diff)`。reducer 在 `turn/diff/updated` 已把 `added`/`removed` 落进 item（见 `ThreadReducer.mutateFile`）。摘要要的是**全会话汇总**的 +/- 行数与改动文件数，抽成纯函数。

- [x] **Step 1: 写失败测试**

在 `WorkspaceSummaryTests.swift` 追加：
```swift
    func testDiffLineCountsSumsAllFileChanges() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .userMessage(id: "u1", text: "hi"),
            .fileChange(id: "f1", file: "a.swift", added: 10, removed: 3, diff: ""),
            .fileChange(id: "f2", file: "b.swift", added: 0, removed: 5, diff: ""),
            .agentMessage(id: "a1", text: "done"),
        ]
        let counts = WorkspaceSummary.diffLineCounts(in: state)
        XCTAssertEqual(counts.added, 10)
        XCTAssertEqual(counts.removed, 8)
        XCTAssertEqual(counts.changedFiles, 2)
    }

    func testDiffLineCountsEmptyWhenNoFileChanges() {
        var state = ConversationState(threadId: "t")
        state.items = [.userMessage(id: "u1", text: "hi")]
        let counts = WorkspaceSummary.diffLineCounts(in: state)
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.removed, 0)
        XCTAssertEqual(counts.changedFiles, 0)
        XCTAssertTrue(counts.isEmpty)
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests/testDiffLineCountsSumsAllFileChanges
```
Expected: 编译失败 / FAIL，"cannot find 'WorkspaceSummary' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Domain/WorkspaceSummary.swift`：
```swift
import Foundation

/// 摘要浮层 P0 数据的派生纯函数集合（无 SwiftUI 依赖，便于单测）。
/// 数据源：ConversationState（diff 行数 / 命令任务 / plan）+ ThreadSummary（cwd）。
enum WorkspaceSummary {

    /// 全会话 diff 行数汇总（来自所有 .fileChange item 的 added/removed）。
    struct DiffLineCounts: Equatable {
        var added: Int
        var removed: Int
        var changedFiles: Int
        var isEmpty: Bool { changedFiles == 0 }
    }

    static func diffLineCounts(in state: ConversationState) -> DiffLineCounts {
        var added = 0, removed = 0, files = 0
        for item in state.items {
            if case .fileChange(_, _, let a, let r, _) = item {
                added += a; removed += r; files += 1
            }
        }
        return DiffLineCounts(added: added, removed: removed, changedFiles: files)
    }
}
```

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests
```
Expected: `TEST SUCCEEDED`。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Domain/WorkspaceSummary.swift ios/CodexRemoteTests/WorkspaceSummaryTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): derive diff line counts for summary"
```

---

## Task 4: 摘要 P0 派生 —— plan 进度归约 + 命令任务列表

**Files:**
- Modify: `ios/CodexRemote/Domain/WorkspaceSummary.swift`
- Test: `ios/CodexRemoteTests/WorkspaceSummaryTests.swift`（追加）

> 「进度」= plan 步骤的完成统计（completed / 总数）+ 步骤明细；「任务」= 会话内 `.commandExecution` items 的命令列表。两者都抽纯函数。

- [x] **Step 1: 写失败测试**

在 `WorkspaceSummaryTests.swift` 追加：
```swift
    func testPlanProgressCountsCompleted() {
        var state = ConversationState(threadId: "t")
        state.plan = [
            TurnPlanStep(step: "a", status: .completed),
            TurnPlanStep(step: "b", status: .completed),
            TurnPlanStep(step: "c", status: .inProgress),
        ]
        let p = WorkspaceSummary.planProgress(in: state)
        XCTAssertEqual(p.completed, 2)
        XCTAssertEqual(p.total, 3)
        XCTAssertEqual(p.steps.count, 3)
        XCTAssertFalse(p.isEmpty)
    }

    func testPlanProgressEmpty() {
        let state = ConversationState(threadId: "t")
        let p = WorkspaceSummary.planProgress(in: state)
        XCTAssertEqual(p.completed, 0)
        XCTAssertEqual(p.total, 0)
        XCTAssertTrue(p.isEmpty)
    }

    func testCommandTasksListsCommandsInOrder() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .commandExecution(id: "c1", command: "ls -la", output: "", status: .completed, exitCode: 0, durationMs: 5),
            .agentMessage(id: "a1", text: "x"),
            .commandExecution(id: "c2", command: "swift build", output: "", status: .inProgress, exitCode: nil, durationMs: nil),
        ]
        let tasks = WorkspaceSummary.commandTasks(in: state)
        XCTAssertEqual(tasks.map(\.command), ["ls -la", "swift build"])
        XCTAssertEqual(tasks.first?.status, .completed)
        XCTAssertEqual(tasks.last?.status, .inProgress)
    }

    func testCommandTasksEmpty() {
        var state = ConversationState(threadId: "t")
        state.items = [.userMessage(id: "u1", text: "hi")]
        XCTAssertTrue(WorkspaceSummary.commandTasks(in: state).isEmpty)
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests/testPlanProgressCountsCompleted
```
Expected: 编译失败 / FAIL，"type 'WorkspaceSummary' has no member 'planProgress'"。

- [x] **Step 3: 写最小实现**

在 `WorkspaceSummary` enum 内（`diffLineCounts` 之后）追加：
```swift
    /// plan 进度：完成数 / 总数 + 步骤明细（直接复用 ConversationState.plan）。
    struct PlanProgress: Equatable {
        var steps: [TurnPlanStep]
        var completed: Int { steps.filter { $0.status == .completed }.count }
        var total: Int { steps.count }
        var isEmpty: Bool { steps.isEmpty }
    }

    static func planProgress(in state: ConversationState) -> PlanProgress {
        PlanProgress(steps: state.plan)
    }

    /// 单条命令任务（摘要「任务」P0）。
    struct CommandTask: Equatable, Identifiable {
        var id: String
        var command: String
        var status: CommandStatus
    }

    /// 会话内所有命令执行项，按出现顺序。
    static func commandTasks(in state: ConversationState) -> [CommandTask] {
        state.items.compactMap { item in
            guard case .commandExecution(let id, let cmd, _, let status, _, _) = item else { return nil }
            return CommandTask(id: id, command: cmd, status: status)
        }
    }
```

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests
```
Expected: `TEST SUCCEEDED`（diff + plan + command 全绿）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Domain/WorkspaceSummary.swift ios/CodexRemoteTests/WorkspaceSummaryTests.swift
git commit -m "feat(workspace): derive plan progress and command tasks for summary"
```

---

## Task 5: 面板最小尺寸常量 + clamp 纯函数

**Files:**
- Create: `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift`
- Test: `ios/CodexRemoteTests/WorkspaceMetricsTests.swift`

> design D3/D4/D5：右栏有最小宽、下栏有最小高，拖动时不得小于最小值。把「常量 + clamp」抽纯函数单测（拖动本身验不了，但 clamp 逻辑可测）。

- [x] **Step 1: 写失败测试**

新建 `ios/CodexRemoteTests/WorkspaceMetricsTests.swift`：
```swift
import XCTest
import CoreGraphics
@testable import CodexRemote

final class WorkspaceMetricsTests: XCTestCase {
    func testClampBelowMinReturnsMin() {
        XCTAssertEqual(WorkspaceMetrics.clamp(50, min: 150, max: 400), 150)
    }
    func testClampAboveMaxReturnsMax() {
        XCTAssertEqual(WorkspaceMetrics.clamp(999, min: 150, max: 400), 400)
    }
    func testClampWithinRangeUnchanged() {
        XCTAssertEqual(WorkspaceMetrics.clamp(220, min: 150, max: 400), 220)
    }
    func testBottomPanelMinHeightConstantPositive() {
        XCTAssertGreaterThan(WorkspaceMetrics.bottomPanelMinHeight, 0)
    }
    func testRightPanelMinWidthConstantPositive() {
        XCTAssertGreaterThan(WorkspaceMetrics.rightPanelMinWidth, 0)
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceMetricsTests
```
Expected: 编译失败 / FAIL，"cannot find 'WorkspaceMetrics' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift`：
```swift
import CoreGraphics

/// 五窗口面板的尺寸常量与 clamp 纯函数（design D3/D4/D5）。
enum WorkspaceMetrics {
    /// 右边栏（inspector）最小 / 理想 / 最大宽。
    static let rightPanelMinWidth: CGFloat = 220
    static let rightPanelIdealWidth: CGFloat = 320
    static let rightPanelMaxWidth: CGFloat = 480

    /// 下边栏最小 / 理想高。
    static let bottomPanelMinHeight: CGFloat = 140
    static let bottomPanelIdealHeight: CGFloat = 220

    /// 把值夹到 [min, max]，供拖动改尺寸时防止越界。
    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }
}
```

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/WorkspaceMetricsTests
```
Expected: `TEST SUCCEEDED`。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/WorkspaceMetrics.swift ios/CodexRemoteTests/WorkspaceMetricsTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): panel size constants and clamp helper"
```

---

## Task 6: 新增本地化键（顶栏按钮 / 面板空态 / 摘要）

**Files:**
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（新增一个键解析断言测试）

> 既有快照测试用「`String(localized:)` 解析失败回落键名本身 → 断言 `!=` 键名」证明键已添加（见 `test_inspector_selected_thread_snapshot`）。先加断言（红），再加键（绿）。新增键：`workspace.leftPanel.toggle`、`workspace.bottomPanel.toggle`、`workspace.rightPanel.toggle`、`workspace.summary.toggle`、`workspace.panel.empty.title`、`workspace.panel.empty.desc`、`workspace.summary.title`、`workspace.summary.diff`、`workspace.summary.cwd`、`workspace.summary.progress`、`workspace.summary.tasks`、`workspace.summary.empty`。

- [x] **Step 1: 写失败测试**

在 `OrientationSnapshotTests.swift` 的 class 内新增：
```swift
    /// 工作区新增本地化键必须可解析（解析失败回落键名本身）。
    func test_workspace_localization_keys_present() {
        for key in ["workspace.leftPanel.toggle", "workspace.bottomPanel.toggle",
                    "workspace.rightPanel.toggle", "workspace.summary.toggle",
                    "workspace.panel.empty.title", "workspace.panel.empty.desc",
                    "workspace.summary.title", "workspace.summary.diff",
                    "workspace.summary.cwd", "workspace.summary.progress",
                    "workspace.summary.tasks", "workspace.summary.empty"] {
            let value = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(value, key, "缺少 \(key) 本地化键")
        }
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_workspace_localization_keys_present
```
Expected: FAIL，断言 "缺少 workspace.leftPanel.toggle 本地化键"。

- [x] **Step 3: 加键**

打开 `ios/CodexRemote/Resources/Localizable.xcstrings`（JSON 格式，顶层 `"strings": { ... }`）。在 `strings` 对象内为每个键加一个条目。逐键追加形如（以下为 zh-Hans + en 两语，匹配仓库现有键的多语结构；若仓库仅单语，按现有键的实际结构对齐）：
```json
"workspace.leftPanel.toggle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Toggle left panel" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "左面板" } }
  }
},
"workspace.bottomPanel.toggle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Toggle bottom panel" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "下面板" } }
  }
},
"workspace.rightPanel.toggle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Toggle right panel" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "右面板" } }
  }
},
"workspace.summary.toggle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Toggle summary" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "摘要" } }
  }
},
"workspace.panel.empty.title" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Nothing here yet" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "暂无内容" } }
  }
},
"workspace.panel.empty.desc" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Content arrives in a later update" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "内容将在后续版本填充" } }
  }
},
"workspace.summary.title" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Summary" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "摘要" } }
  }
},
"workspace.summary.diff" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Changes" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "变更" } }
  }
},
"workspace.summary.cwd" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Working directory" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "工作目录" } }
  }
},
"workspace.summary.progress" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Progress" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "进度" } }
  }
},
"workspace.summary.tasks" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Tasks" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "任务" } }
  }
},
"workspace.summary.empty" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "No summary data yet" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "暂无摘要数据" } }
  }
}
```
注意：确保最终 JSON 合法（条目间逗号、不破坏既有键）。可用 `python3 -m json.tool ios/CodexRemote/Resources/Localizable.xcstrings >/dev/null && echo OK` 校验。

- [x] **Step 4: 运行测试确认通过**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_workspace_localization_keys_present
```
Expected: `TEST SUCCEEDED`。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/OrientationSnapshotTests.swift
git commit -m "feat(workspace): add localization keys for panels and summary"
```

---

## Task 7: 共享面板空态视图

**Files:**
- Create: `ios/CodexRemote/Views/Workspace/PanelEmptyState.swift`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（快照）

> design D5：右栏 / 下栏共享空态视图。本期它们都只显空态。用 `ContentUnavailableView`（与 `SidebarView` / `InspectorView` 一致）。

- [x] **Step 1: 写失败测试（快照 + 可判定断言）**

在 `OrientationSnapshotTests.swift` 新增：
```swift
    /// 共享空态视图：渲染不崩溃、PNG 非空，落 /tmp/workspace。
    func test_panel_empty_state_snapshot() {
        let view = PanelEmptyState()
            .environment(LocaleManager())
            .frame(width: 320, height: 240)
        snapshot(view, size: CGSize(width: 320, height: 240),
                 name: "panel-empty", dir: "/tmp/workspace")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_panel_empty_state_snapshot
```
Expected: 编译失败，"cannot find 'PanelEmptyState' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Views/Workspace/PanelEmptyState.swift`：
```swift
import SwiftUI

/// 右栏 / 下栏占位空态（design D5：本期无真实内容，后续 change 填充）。
struct PanelEmptyState: View {
    var body: some View {
        ContentUnavailableView("workspace.panel.empty.title",
                               systemImage: "rectangle.dashed",
                               description: Text("workspace.panel.empty.desc"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
```

- [x] **Step 4: 运行测试确认通过 + 目视**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_panel_empty_state_snapshot
```
Expected: `TEST SUCCEEDED`。目视 `/tmp/workspace/panel-empty.png`：居中空态图标 + 标题 + 描述。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/PanelEmptyState.swift ios/CodexRemoteTests/OrientationSnapshotTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): shared panel empty-state view"
```

---

## Task 8: 摘要悬浮浮层内容视图（SummaryPopoverView）

**Files:**
- Create: `ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（有数据态 + 空态两张快照）

> design D2：消费 Task 3/4 的派生数据（diff 行数 / cwd / plan 进度 / 命令任务）。输入用 `ConversationState?` + `ThreadSummary?`，全空时显空态。内容自适应（用 `List`/`VStack`，不强制整列宽——`.popover` 会自适应）。

- [x] **Step 1: 写失败测试**

在 `OrientationSnapshotTests.swift` 新增：
```swift
    /// 摘要浮层有数据态：diff / cwd / plan / 任务都渲染，PNG 非空。
    func test_summary_popover_with_data_snapshot() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .fileChange(id: "f1", file: "a.swift", added: 12, removed: 4, diff: ""),
            .commandExecution(id: "c1", command: "swift build", output: "",
                              status: .completed, exitCode: 0, durationMs: 9),
        ]
        state.plan = [
            TurnPlanStep(step: "读代码", status: .completed),
            TurnPlanStep(step: "写测试", status: .inProgress),
        ]
        let thread = gitThread("sum1", cwd: "/repo/web-dev", origin: "o/web", ago: 60, name: "重构")
        let view = SummaryPopoverView(state: state, thread: thread)
            .environment(LocaleManager())
            .frame(width: 360, height: 480)
        snapshot(view, size: CGSize(width: 360, height: 480),
                 name: "summary-with-data", dir: "/tmp/workspace")
    }

    /// 摘要浮层空态：无 state / 无 thread → 空态占位，不崩溃。
    func test_summary_popover_empty_snapshot() {
        let view = SummaryPopoverView(state: nil, thread: nil)
            .environment(LocaleManager())
            .frame(width: 360, height: 200)
        snapshot(view, size: CGSize(width: 360, height: 200),
                 name: "summary-empty", dir: "/tmp/workspace")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_summary_popover_with_data_snapshot
```
Expected: 编译失败，"cannot find 'SummaryPopoverView' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift`：
```swift
import SwiftUI

/// 摘要悬浮浮层内容（design D2）：diff 行数 / cwd / 进度(plan) / 任务(命令)。
/// 输入为当前会话状态与选中线程；全无数据时显空态。内容自适应（List 高度随内容）。
struct SummaryPopoverView: View {
    let state: ConversationState?
    let thread: ThreadSummary?

    private var diff: WorkspaceSummary.DiffLineCounts {
        state.map(WorkspaceSummary.diffLineCounts(in:)) ?? .init(added: 0, removed: 0, changedFiles: 0)
    }
    private var progress: WorkspaceSummary.PlanProgress {
        state.map(WorkspaceSummary.planProgress(in:)) ?? .init(steps: [])
    }
    private var tasks: [WorkspaceSummary.CommandTask] {
        state.map(WorkspaceSummary.commandTasks(in:)) ?? []
    }
    private var cwd: String? { thread?.cwd }

    private var isEmpty: Bool {
        diff.isEmpty && progress.isEmpty && tasks.isEmpty && (cwd?.isEmpty ?? true)
    }

    var body: some View {
        if isEmpty {
            ContentUnavailableView("workspace.summary.empty", systemImage: "list.bullet.rectangle")
                .padding()
        } else {
            List {
                if !diff.isEmpty {
                    Section("workspace.summary.diff") {
                        Text("+\(diff.added)  −\(diff.removed)  ·  \(diff.changedFiles)")
                            .monospacedDigit()
                    }
                }
                if let cwd, !cwd.isEmpty {
                    Section("workspace.summary.cwd") {
                        Text(cwd).lineLimit(2).font(.callout)
                    }
                }
                if !progress.isEmpty {
                    Section("workspace.summary.progress \(progress.completed) \(progress.total)") {
                        ForEach(Array(progress.steps.enumerated()), id: \.offset) { _, step in
                            Label {
                                Text(step.step).lineLimit(1)
                            } icon: {
                                Image(systemName: icon(for: step.status))
                            }
                        }
                    }
                }
                if !tasks.isEmpty {
                    Section("workspace.summary.tasks") {
                        ForEach(tasks) { task in
                            Text(task.command).font(.caption).monospaced().lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func icon(for status: TurnPlanStepStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.dashed"
        case .pending: return "circle"
        }
    }
}
```
注：`"workspace.summary.progress \(progress.completed) \(progress.total)"` 用了带参数本地化键。Task 6 加的 `workspace.summary.progress` value 需含两个占位符，例如 zh-Hans 改为 `"进度 %1$lld/%2$lld"`、en 改为 `"Progress %1$lld/%2$lld"`。若 Task 6 未带占位符，本步同时回 Task 6 的 xcstrings 把 `workspace.summary.progress` 的 value 改成上面带 `%1$lld/%2$lld` 的形式（并保持 `test_workspace_localization_keys_present` 仍能解析为非键名）。

- [x] **Step 4: 运行测试确认通过 + 目视**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_summary_popover_with_data_snapshot \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_summary_popover_empty_snapshot
```
Expected: `TEST SUCCEEDED`。目视 `/tmp/workspace/summary-with-data.png`（四区分组：变更 / 工作目录 / 进度勾选圈 / 任务命令）与 `summary-empty.png`（居中空态）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/SummaryPopoverView.swift ios/CodexRemote/Resources/Localizable.xcstrings ios/CodexRemoteTests/OrientationSnapshotTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): summary popover content with P0 data and empty state"
```

---

## Task 9: 右边栏占位视图（RightPanelView）

**Files:**
- Create: `ios/CodexRemote/Views/Workspace/RightPanelView.swift`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（快照）

> design D3：右栏本期只裹共享空态。真实显隐 / 拖动 / 最小宽在 Task 11 接到 `.inspector`。本任务只产出可独立渲染的占位视图。

- [x] **Step 1: 写失败测试**

```swift
    func test_right_panel_snapshot() {
        let view = RightPanelView()
            .environment(LocaleManager())
            .frame(width: 320, height: 600)
        snapshot(view, size: CGSize(width: 320, height: 600),
                 name: "right-panel", dir: "/tmp/workspace")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_right_panel_snapshot
```
Expected: 编译失败，"cannot find 'RightPanelView' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Views/Workspace/RightPanelView.swift`：
```swift
import SwiftUI

/// 右边栏整列面板（design D3）。本期占位空态，后续 change 填 Diff/文件/终端 tab。
struct RightPanelView: View {
    var body: some View {
        PanelEmptyState()
    }
}
```

- [x] **Step 4: 运行测试确认通过 + 目视**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_right_panel_snapshot
```
Expected: `TEST SUCCEEDED`。目视 `/tmp/workspace/right-panel.png`：空态占位铺满。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/RightPanelView.swift ios/CodexRemoteTests/OrientationSnapshotTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): right panel placeholder view"
```

---

## Task 10: 下边栏占位视图 + 可拖高度容器（BottomPanelView）

**Files:**
- Create: `ios/CodexRemote/Views/Workspace/BottomPanelView.swift`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（快照）

> design D4：下栏 = 顶部一条可拖 Divider（调高）+ 空态内容。高度由父级 `@State` 持有；本视图接收 `height` 绑定与拖动手势回调（拖动 clamp 用 `WorkspaceMetrics.clamp`）。拖动效果靠用户/UI 测试确认，本任务快照只验空态渲染 + 拖动条存在。

- [x] **Step 1: 写失败测试**

```swift
    func test_bottom_panel_snapshot() {
        let view = BottomPanelView(height: .constant(WorkspaceMetrics.bottomPanelIdealHeight))
            .environment(LocaleManager())
            .frame(width: 800, height: 260)
        snapshot(view, size: CGSize(width: 800, height: 260),
                 name: "bottom-panel", dir: "/tmp/workspace")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_bottom_panel_snapshot
```
Expected: 编译失败，"cannot find 'BottomPanelView' in scope"。

- [x] **Step 3: 写最小实现**

新建 `ios/CodexRemote/Views/Workspace/BottomPanelView.swift`：
```swift
import SwiftUI

/// 下边栏（design D4）：顶部可拖把手（调高，clamp 到最小高）+ 占位空态。
/// 高度由父级（detail 区 VStack）持有并绑定进来；拖动时改 height。
struct BottomPanelView: View {
    @Binding var height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            PanelEmptyState()
        }
        .frame(height: height)
    }

    /// 可拖把手：纵向拖动改高，松手 clamp 到 [min, max]。
    /// 拖动效果（手势）靠模拟器/UI 测试确认；clamp 逻辑已在 WorkspaceMetricsTests 单测。
    private var dragHandle: some View {
        ZStack {
            Rectangle().fill(.bar).frame(height: 16)
            Capsule().fill(.secondary).frame(width: 40, height: 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 向上拖（dy<0）增高；clamp 到 [min, 屏高的合理上界]。
                    let proposed = height - value.translation.height
                    height = WorkspaceMetrics.clamp(proposed,
                                                    min: WorkspaceMetrics.bottomPanelMinHeight,
                                                    max: 900)
                }
        )
        .accessibilityLabel(Text("workspace.bottomPanel.toggle"))
    }
}
```

- [x] **Step 4: 运行测试确认通过 + 目视**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_bottom_panel_snapshot
```
Expected: `TEST SUCCEEDED`。目视 `/tmp/workspace/bottom-panel.png`：顶部把手 + 下方空态。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/Workspace/BottomPanelView.swift ios/CodexRemoteTests/OrientationSnapshotTests.swift ios/CodexRemote.xcodeproj
git commit -m "feat(workspace): bottom panel placeholder with draggable handle"
```

---

## Task 11: RootSplitView 顶栏 5 按钮重排 + 接线右栏(inspector)/下栏/摘要 popover

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`（整体重写，见下完整文件）
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（默认态 + 全开态两张快照）

> 核心装配。顶栏按钮左→右：左面板 / 下面板 / 右面板 / 摘要(`:≡`) / 设置（去前进后退、不叠加系统 `sidebarToggle`）。摘要按钮上挂 `.popover`。detail 区改 `VStack { 上半(content + `.inspector`) ; 下栏(条件) }`，使下栏只压短中间+右栏（design D4），左栏满高（design 层级图）。摘要数据需要当前会话 state——本期 `RootSplitView` 不持有 `ConversationStore`（在 `ConversationView` 内），故摘要 popover 先用「选中线程的 `ThreadSummary`（cwd）」+ 空 state（plan/diff/tasks 走空态）。真实 state 接线见 Task 12。

- [x] **Step 1: 写失败测试**

在 `OrientationSnapshotTests.swift` 新增：
```swift
    /// 工作区默认态：右/下栏隐藏、摘要关。顶栏 5 按钮辅助标签键须可解析。
    func test_workspace_default_layout_snapshot() {
        for key in ["workspace.leftPanel.toggle", "workspace.bottomPanel.toggle",
                    "workspace.rightPanel.toggle", "workspace.summary.toggle"] {
            let v = String(localized: String.LocalizationValue(key), bundle: .main)
            XCTAssertNotEqual(v, key, "缺少 \(key)")
        }
        let view = RootSplitView()
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: landscape, name: "workspace-default", dir: "/tmp/workspace")
    }

    /// 工作区全开态（右栏 + 下栏初始展开）：验证层级——左栏满高、下栏在 detail 区内。
    /// 用注入初始展开态的便利初始化器（见实现 Step 3）。
    func test_workspace_all_panels_snapshot() {
        let view = RootSplitView(initialRightOpen: true, initialBottomOpen: true)
            .environment(makeConnection())
            .environment(makeProjects())
            .environment(LocaleManager())
            .environment(ThemeManager())
        snapshot(view, size: landscape, name: "workspace-all-open", dir: "/tmp/workspace")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_workspace_all_panels_snapshot
```
Expected: 编译失败，"extra argument 'initialRightOpen' in call"（旧 `RootSplitView` 无此初始化器）。

- [x] **Step 3: 重写 RootSplitView（完整文件）**

把 `ios/CodexRemote/Views/RootSplitView.swift` 整体替换为：
```swift
import SwiftUI

/// 主界面（复刻 Codex desktop 五窗口工作区骨架）：
/// 顶部固定全局工具栏（safeAreaInset，不用 VStack 包整个 split，避免破坏 inspector 拖动）
/// + NavigationSplitView：左边栏(满高) | detail 区。
/// detail 区 = VStack { 上半(中间对话 + 右栏 .inspector) ; 下栏(条件) }，
/// 故下栏只压短「中间 + 右栏」、不伸到左边栏（design D4 / 布局层级）。
/// 摘要为 :≡ 按钮触发的 .popover（design D2），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // 五窗口 toggle 状态（design D5：每个面板一个 @State Bool）。
    @State private var showRightPanel: Bool
    @State private var showBottomPanel: Bool
    @State private var showSummary = false
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

    /// 便利初始化：允许注入面板初始展开态（供快照测试覆盖全开布局）。
    init(initialRightOpen: Bool = false, initialBottomOpen: Bool = false) {
        _showRightPanel = State(initialValue: initialRightOpen)
        _showBottomPanel = State(initialValue: initialBottomOpen)
    }

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    var body: some View {
        split
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                }
            }
    }

    // MARK: - 顶部固定全局工具栏：左面板 · 下面板 · 右面板 · 摘要(:≡) · 设置

    private var topBar: some View {
        HStack(spacing: 18) {
            // 左面板：显式控制 columnVisibility（不叠加系统 sidebarToggle）。
            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: { Image(systemName: "sidebar.leading") }
            .accessibilityLabel(Text("workspace.leftPanel.toggle"))

            // 下面板。
            Button { withAnimation { showBottomPanel.toggle() } } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .accessibilityLabel(Text("workspace.bottomPanel.toggle"))

            // 右面板。
            Button { withAnimation { showRightPanel.toggle() } } label: {
                Image(systemName: "sidebar.right")
            }
            .accessibilityLabel(Text("workspace.rightPanel.toggle"))

            // 摘要(:≡)：Codex 真实 panel-right SVG（关=描边 / 开=填充）。.popover 挂在此按钮。
            Button { showSummary.toggle() } label: {
                Image(showSummary ? "InspectorOpen" : "InspectorClosed")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(Text("workspace.summary.toggle"))
            .popover(isPresented: $showSummary) {
                SummaryPopoverView(state: nil, thread: selectedThread)
            }

            Spacer()

            SettingsMenu()
        }
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - split：左栏满高 | detail 区(VStack)

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .toolbar(removing: .sidebarToggle)
                .toolbarBackground(.hidden, for: .navigationBar)
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // detail = 上半(content + 右栏 inspector) + 下栏(条件)。下栏在此 VStack 内 → 不压左栏。
    private var detail: some View {
        VStack(spacing: 0) {
            content
                .inspector(isPresented: $showRightPanel) {
                    RightPanelView()
                        .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                              ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                              max: WorkspaceMetrics.rightPanelMaxWidth)
                }
            if showBottomPanel {
                Divider()
                BottomPanelView(height: $bottomHeight)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(threadId: id).id(id)
        } else {
            Color(.systemBackground)
        }
    }
}
```

- [x] **Step 4: 运行测试确认通过 + 目视层级**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_workspace_default_layout_snapshot \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_workspace_all_panels_snapshot
```
Expected: `TEST SUCCEEDED`。目视 `/tmp/workspace/workspace-all-open.png`：左栏满高到底；下栏空态横跨中间+右栏区、未伸到左栏底下；右栏空态在中间右侧。（拖动改宽/高靠模拟器交互或 UI 测试确认——见计划顶部测试约定。）

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemoteTests/OrientationSnapshotTests.swift
git commit -m "feat(workspace): wire five-window shell into RootSplitView (topbar/inspector/bottom/summary)"
```

---
: 摘要 popover 接真实会话 state（diff/plan/tasks 不再恒空）

**Files:**
- Modify: `ios/CodexRemote/Views/RootSplitView.swift`
- Modify: `ios/CodexRemote/Views/ConversationView.swift`
- Test: `ios/CodexRemoteTests/OrientationSnapshotTests.swift`（接线后默认态仍渲染，不回归）

> Task 11 摘要只给了 cwd（`SummaryPopoverView(state: nil, ...)`），diff/plan/tasks 恒空。会话 state 在 `ConversationView` 内的 `ConversationStore`。为让顶栏摘要拿到当前会话 state，把「当前会话 state」上提为可被 `RootSplitView` 读取的共享值：用一个轻量 `@Observable` 持有者，`ConversationView` 写入、`RootSplitView` 读出。最小改动、不动归约逻辑。

- [x] **Step 1: 写失败测试**

在 `OrientationSnapshotTests.swift` 新增（验证新持有者类型存在 + 默认态不回归）：
```swift
    func test_active_conversation_holder_default_nil() {
        let holder = ActiveConversationHolder()
        XCTAssertNil(holder.state)
    }
```

- [x] **Step 2: 运行测试确认失败**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests/test_active_conversation_holder_default_nil
```
Expected: 编译失败，"cannot find 'ActiveConversationHolder' in scope"。

- [x] **Step 3: 实现共享持有者并接线**

3a. 在 `ios/CodexRemote/Views/RootSplitView.swift` 顶部（`struct RootSplitView` 之前）加：
```swift
import Observation

/// 当前活跃会话状态的共享持有者：ConversationView 写入最新 state，
/// 顶栏摘要 popover 读出用于派生 diff/plan/tasks（cwd 仍取选中 ThreadSummary）。
@Observable
@MainActor
final class ActiveConversationHolder {
    var state: ConversationState?
}
```

3b. 在 `RootSplitView` 内加 `@State private var activeConversation = ActiveConversationHolder()`，并把它注入环境 + 摘要 popover 改读它：
- `body` 的 `split.safeAreaInset...` 链尾加 `.environment(activeConversation)`。
- 摘要 popover 改为：
```swift
            .popover(isPresented: $showSummary) {
                SummaryPopoverView(state: activeConversation.state, thread: selectedThread)
            }
```

3c. 在 `ios/CodexRemote/Views/ConversationView.swift`：
- 顶部加 `@Environment(ActiveConversationHolder.self) private var activeConversation`。
- 在 `.task(id: threadId)` 内 `store = s` 之后、以及对话变化时同步 state。最稳妥：加一个 `.onChange(of: store?.state)` 把最新 state 写回 holder，并在切换线程/消失时清空：
```swift
        .onChange(of: store?.state) { _, newValue in
            activeConversation.state = newValue
        }
        .onDisappear { activeConversation.state = nil }
```
（`ConversationState` 已 `Equatable`，`onChange` 可用。）

- [x] **Step 4: 运行测试确认通过 + 全量回归**

Run（接线测试 + 默认/全开布局回归 + 摘要内容快照）：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -only-testing:CodexRemoteTests/OrientationSnapshotTests \
  -only-testing:CodexRemoteTests/WorkspaceSummaryTests \
  -only-testing:CodexRemoteTests/WorkspaceMetricsTests \
  -only-testing:CodexRemoteTests/ThreadReducerTests
```
Expected: `TEST SUCCEEDED`，全部快照重新生成（目视 `/tmp/workspace/` 与 `/tmp/orient/` 无回归）。

- [x] **Step 5: 提交**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemote/Views/ConversationView.swift ios/CodexRemoteTests/OrientationSnapshotTests.swift
git commit -m "feat(workspace): feed live conversation state into summary popover"
```

---

## Task 13: 全量编译 + 全量测试 + tasks.md 勾选

**Files:**
- Modify: `openspec/changes/ipad-workspace-shell/tasks.md`（勾选完成项）

- [ ] **Step 1: 全量 build**

Run：
```bash
xcodebuild build -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 2: 全量 test**

Run：
```bash
xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData
```
Expected: `TEST SUCCEEDED`（既有套件 + 新增 `WorkspaceSummaryTests` / `WorkspaceMetricsTests` / reducer plan / 工作区快照全绿）。

- [ ] **Step 3: 勾选 tasks.md**

把 `openspec/changes/ipad-workspace-shell/tasks.md` 的骨架项打勾：1.1 / 1.2 / 2.1 / 2.2 / 2.3 / 3.1 / 3.2 / 4.1 / 4.2 / 5.1 / 6.1（6.1 中「拖动」标注靠 UI 测试或用户确认）。6.2 真机为 follow-up，保持未勾并注明延期。

- [ ] **Step 4: 目视自检（模拟器逐态截图复核，对照 design §4）**

复核 `/tmp/workspace/` 下：
- `workspace-default.png`：顶栏 5 按钮（左面板 / 下面板 / 右面板 / 摘要 / 设置），右/下栏隐藏。
- `workspace-all-open.png`：左栏满高、下栏压短中间+右栏不伸到左栏、右栏在中间右侧。
- `summary-with-data.png` / `summary-empty.png`：摘要四区 / 空态。
- `right-panel.png` / `bottom-panel.png` / `panel-empty.png`：空态占位。
列出任何与 design 层级图不符之处，交用户确认或转 verify 阶段处理。

- [ ] **Step 5: 提交**

```bash
git add openspec/changes/ipad-workspace-shell/tasks.md
git commit -m "chore(workspace): check off skeleton tasks after build+test green"
```

---

## Self-Review（计划对照 spec）

**1. Spec coverage（delta spec 逐条）：**
- 五窗口布局与层级（下栏不压左栏 / 横屏五窗口同屏）→ Task 11 detail 区 VStack 结构 + `test_workspace_all_panels_snapshot`。
- 顶部固定全局工具栏（5 按钮 / 设置常显）→ Task 11 topBar。
- 摘要悬浮浮层（P0 内容 + 自适应 + 空态）→ Task 8（视图）+ Task 12（接真实 state）+ Task 3/4（派生）+ Task 1/2（plan 数据）。
- 右边栏（显隐 + 可拖 + 最小宽 + 空态）→ Task 9（空态）+ Task 11（`.inspector` + `inspectorColumnWidth(min:)`）。
- 下边栏（显隐 + 可拖 + 最小高 + 空态）→ Task 10（可拖容器 + clamp）+ Task 11（toggle）+ Task 5（min 常量）。
- session-management MODIFIED（摘要改浮层、设置常显、默认聚焦侧栏）→ Task 11（默认 `columnVisibility=.all`、摘要默认关、设置 `SettingsMenu` 常驻）。
- tasks.md 1.1–6.1 → 覆盖；6.2 真机为 follow-up（明确延期）。

**2. Placeholder scan：** 各步均含真实 Swift 代码 / 命令 / 期望输出，无 TBD / "类似上面"。

**3. Type consistency：** `TurnPlanStep`/`TurnPlanStepStatus`（Task 1）、`ConversationState.plan`（Task 2）、`WorkspaceSummary.{diffLineCounts,planProgress,commandTasks}` 与返回类型 `DiffLineCounts`/`PlanProgress`/`CommandTask`（Task 3/4，Task 8 消费一致）、`WorkspaceMetrics.{clamp,rightPanelMinWidth,bottomPanelMinHeight,...}`（Task 5，Task 10/11 复用一致）、`ActiveConversationHolder.state`（Task 12）签名前后一致。

**已知风险 / 留待 verify：** (a) `turn/plan/updated` 真实字段形状未由仓库样本固化，Task 2 用容错读取，真机/真数据若字段名不同需在 verify 阶段按实测调整。(b) 拖动手势效果离屏快照验不了，靠模拟器交互或 UI 测试 + 用户确认。(c) xcstrings 带参数键 `workspace.summary.progress` 的占位符格式需 Task 6/8 对齐（已在 Task 8 Step 3 注明）。
