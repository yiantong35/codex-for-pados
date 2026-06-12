---
change: ipad-codex-remote-client
design-doc: docs/superpowers/specs/2026-06-11-ipad-codex-remote-client-design.md
base-ref: 5ddabc7d3a2f4402cd048a6cb57d8a460f440934
---

# iPad Codex 远程 GUI 客户端 实现计划

> **致执行者（agentic worker）：** 必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现本计划。各步骤用复选框（`- [ ]`）语法跟踪进度。

**目标：** 构建一个 iPadOS 原生 SwiftUI app，经 SSH 连接 Mac 上的 `codex app-server`（官方 SSH 远程控制：受管 daemon 暴露的 control socket，JSON-RPC 2.0 over stdio），复刻 Codex 桌面 app 的左栏（项目→对话树）+ 中栏（流式正文/命令输出/文件 diff/多选项审批卡），并支持恢复桌面会话、图片附件、模型/推理可调、转向(steer)/排队/中断。

**架构：** 五层自下而上 — 传输层（Citadel SSH exec 通道运行远端 `codex app-server proxy` → JSON-RPC over stdio（换行分隔），actor）→ JSON-RPC 层（id 关联 + 通知 async 流 + server→client 请求分发，actor）→ 领域/归约层（schema 派生的 `Codable` 类型 + `ThreadReducer`）→ 状态层（`@Observable` Stores）→ SwiftUI 三栏 `NavigationSplitView`。协议类型由 `codex app-server generate-json-schema/generate-ts` 生成（pin codex 0.133.0），协议层隔离以便升级。

**技术栈：** Swift 6 / SwiftUI / Observation 框架 / [Citadel](https://github.com/orlandos-nl/Citadel)（SPM，基于 Apple swift-nio-ssh，提供 SSH 连接 + exec 通道）/ XCTest / 录制 fixture + mock 传输做单元测试。

**设计文档：** 详见 `docs/superpowers/specs/2026-06-11-ipad-codex-remote-client-design.md`。本计划是该设计的可执行展开，任务按依赖排序，**技术验证 spike 在最前**（设计 §11 风险最大项：Citadel 在 iPadOS 的 SSH exec 通道长连接 + 双向流式稳定性，及 `codex app-server proxy` 长连接稳定性未知）。

**对应 delta spec（验收事实源）：**
- `openspec/changes/ipad-codex-remote-client/specs/mac-launcher/spec.md`
- `openspec/changes/ipad-codex-remote-client/specs/remote-connection/spec.md`
- `openspec/changes/ipad-codex-remote-client/specs/conversation-streaming/spec.md`
- `openspec/changes/ipad-codex-remote-client/specs/session-management/spec.md`
- `openspec/changes/ipad-codex-remote-client/specs/approval-flow/spec.md`

**协议事实来源（已用真实 codex 0.133.0 验证）：** 生成产物现暂存于 `/tmp/codex-appserver-schema`（JSON Schema）与 `/tmp/codex-appserver-ts`（TS 类型）；本计划要求实现者**在仓库内重新生成**（见 Task 1），不依赖 /tmp 临时目录。下文 Codable 类型字段名与 decision 形状均取自该真实 schema。

---

## 任务依赖总览

```
Task 0  仓库脚手架 + 工具链（Xcode 工程 / SPM / 目录约定）
Task 1  生成协议 schema 纳入仓库 + pin 版本校验文件
Task 2  Mac 端一键启动脚本（mac-launcher，可并行）
Task 3  ★SPIKE★ Citadel SSH exec 远端 codex app-server proxy + initialize 握手（最大未知风险，先打通）
Task 4  协议层：JSON-RPC 信封 Codable + 编解码（fixture 单测）
Task 5  协议层：MVP 领域类型 Codable（initialize/thread/turn/approval）
Task 6  传输层：SSHClient（封装 spike 成果为可复用 actor）
Task 7  传输层：ProxyChannel（actor，exec stdio 上换行分隔 JSON 帧收发）
Task 8  JSON-RPC 层：JSONRPCClient（id 关联 + 通知流 + server 请求分发）
Task 9  归约层：ThreadReducer（notification → 会话状态，fixture 单测）
Task 10 状态层：ConnectionStore（连接生命周期状态机 + 重连）
Task 11 凭证安全存储：KeychainStore + 连接配置界面
Task 12 状态层：ProjectsStore（thread/list 按 cwd 分组 + 待批准徽标）
Task 13 SwiftUI：左栏（项目→对话树）+ 三栏骨架
Task 14 状态层：ConversationStore（resume/start/turn + 流式归约接线）
Task 15 SwiftUI：中栏对话流（正文/命令输出/文件 diff 卡）
Task 16 composer：文本/图片/模型推理选择 + turn/start 映射
Task 17 中途控制：steer / 排队 / interrupt
Task 18 状态层 + UI：ApprovalStore + 多选项审批卡（含 legacy 兼容）
Task 19 审批边界：serverRequest/resolved + 超时/断线不自动批准
Task 20 E2E 联调与验收（4 个手动 E2E 场景）
```

依赖关系：Task 0/1 是一切前提；Task 2 可与 3 并行；Task 3 spike 必须先于 6/7/8 铺开；Task 4/5（纯 Codable + 单测）可在 spike 进行时并行；Task 8 依赖 6/7；Task 9 依赖 5；Task 10 依赖 8；后续 UI/Store 任务线性铺开；Task 20 依赖全部。

---

## Task 0：仓库脚手架 + 工具链约定

建立 Xcode 工程与目录结构。这是后续所有任务落地的物理位置。

**Files:**
- Create: `ios/CodexRemote.xcodeproj`（Xcode 生成的 SwiftUI App 工程）
- Create: `ios/CodexRemote/CodexRemoteApp.swift`
- Create: `ios/CodexRemote/Info.plist`（含本地网络权限说明）
- Create: `ios/Package.swift` 或在工程内添加 SPM 依赖 Citadel
- Create: `docs/superpowers/plans/README-dev-setup.md`（开发环境说明）
- Modify: `.gitignore`（追加 Xcode/SPM 产物忽略项）

- [x] **Step 1：用 Xcode 创建 iPadOS App 工程**

在 `ios/` 下创建名为 `CodexRemote` 的 SwiftUI App（Interface=SwiftUI，Language=Swift，最低部署目标 iPadOS 17.0 以支持 Observation 框架）。Bundle ID 用 `com.<你的开发者前缀>.codexremote`（侧载开发者签名，不上架）。

- [x] **Step 2：建立源码目录约定**

在 `ios/CodexRemote/` 下创建空目录（含 `.gitkeep`）以锁定分层边界，每层一个目录：

```
ios/CodexRemote/
  App/            # CodexRemoteApp.swift、根视图
  Transport/      # SSHClient、ProxyChannel
  RPC/            # JSONRPCClient、信封类型
  Protocol/       # 生成的 Codable 类型 + 手写补充
  Domain/         # ThreadReducer、领域模型
  Stores/         # @Observable Stores
  Views/          # SwiftUI 视图（Sidebar / Conversation / Composer / Approval）
  Security/       # KeychainStore
```

- [x] **Step 3：添加 Citadel SPM 依赖**

在 Xcode 工程中 File → Add Package Dependencies，输入 `https://github.com/orlandos-nl/Citadel`，选择最新稳定版本，加入 `CodexRemote` target。

- [x] **Step 4：配置 Info.plist 本地网络权限**

在 `Info.plist` 加入本地网络访问用途说明（连接 LAN 内 Mac 需要）：

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>连接同一局域网内你的 Mac 上运行的 Codex 服务。</string>
```

- [x] **Step 5：更新 .gitignore**

向 `.gitignore` 追加（不要删除已有行）：

```
# Xcode / SwiftPM
ios/**/xcuserdata/
ios/**/.build/
ios/**/DerivedData/
*.xcuserstate
.swiftpm/
```

- [x] **Step 6：确认工程可编译运行空壳**

Run（在 Xcode 选 iPad 模拟器）：构建并启动，应看到默认空白 SwiftUI 视图，无编译错误。
Expected：构建成功，模拟器显示空白窗口。

- [x] **Step 7：写开发环境说明文档**

`docs/superpowers/plans/README-dev-setup.md` 写明：最低 iPadOS 版本、Citadel 版本、如何选择真机/模拟器、如何配合 Mac 端启动脚本（指向 Task 2 产物）。

- [x] **Step 8：Commit**

```bash
git add ios .gitignore docs/superpowers/plans/README-dev-setup.md
git commit -m "chore: scaffold iPad CodexRemote SwiftUI app + Citadel dependency"
```

---

## Task 1：生成协议 schema 纳入仓库 + pin 版本

**对应 spec：** 全局前提（设计 §4、D3）。协议层的所有 Codable 类型以此为事实源。

**Files:**
- Create: `protocol/codex-version.txt`（pin 的版本号）
- Create: `protocol/schema/`（`generate-json-schema` 输出）
- Create: `protocol/ts/`（`generate-ts` 输出，供人工对照字段名）
- Create: `scripts/regen-protocol.sh`（一键重生成脚本）

- [x] **Step 1：写版本 pin 文件**

`protocol/codex-version.txt` 内容（单行）：

```
0.133.0
```

- [x] **Step 2：写重生成脚本**

`scripts/regen-protocol.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
PIN="$(cat "$(dirname "$0")/../protocol/codex-version.txt")"
ACTUAL="$(codex --version | awk '{print $NF}')"
if [ "$ACTUAL" != "$PIN" ]; then
  echo "ERROR: codex 版本 $ACTUAL != pin $PIN，协议可能不兼容。中止。" >&2
  exit 1
fi
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/protocol"
rm -rf "$OUT_DIR/schema" "$OUT_DIR/ts"
mkdir -p "$OUT_DIR/schema" "$OUT_DIR/ts"
codex app-server generate-json-schema --out "$OUT_DIR/schema"
codex app-server generate-ts --out "$OUT_DIR/ts"
echo "OK: 协议产物已生成到 $OUT_DIR（codex $PIN）"
```

> 注：若 `generate-json-schema`/`generate-ts` 的实际参数名与 `--out` 不同，以 `codex app-server generate-json-schema --help` 为准修正脚本，但仍输出到 `protocol/schema` 与 `protocol/ts`。

- [x] **Step 3：运行脚本生成产物到仓库内**

Run：

```bash
chmod +x scripts/regen-protocol.sh && ./scripts/regen-protocol.sh
```

Expected：打印 `OK: 协议产物已生成`，`protocol/schema/` 下出现 `ServerRequest.json`、`CommandExecutionRequestApprovalResponse.json`、`JSONRPCMessage.json` 等文件；`protocol/ts/` 下出现 `InitializeParams.ts`、`v2/TurnStartParams.ts` 等。

- [x] **Step 4：校验关键文件存在（防生成不全）**

Run：

```bash
ls protocol/schema/ServerRequest.json \
   protocol/schema/CommandExecutionRequestApprovalResponse.json \
   protocol/schema/FileChangeRequestApprovalResponse.json \
   protocol/ts/v2/TurnStartParams.ts \
   protocol/ts/v2/UserInput.ts \
   protocol/ts/ReviewDecision.ts
```

Expected：6 个路径全部存在，无 `No such file`。

- [x] **Step 5：Commit**

```bash
git add protocol scripts/regen-protocol.sh
git commit -m "feat(protocol): generate app-server schema/ts into repo, pin codex 0.133.0"
```

---

## Task 2：Mac 端一键启动脚本（mac-launcher）

**对应 spec：** `mac-launcher/spec.md` 全部场景（正常启用远程控制并输出连接信息 / sshd 未开启时提示 / daemon 已运行 / codex 版本不符合 pin）。

**Files:**
- Create: `scripts/start-codex-appserver.sh`

> 本任务无 Swift 代码，纯 shell。可与 Task 3 spike 并行。验证靠在真实 Mac 上运行脚本（手动），无单元测试。

- [x] **Step 1：写启动脚本骨架与参数**

`scripts/start-codex-appserver.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

PIN_FILE="$(cd "$(dirname "$0")/.." && pwd)/protocol/codex-version.txt"
PIN="$(cat "$PIN_FILE" 2>/dev/null || echo "unknown")"

# 1) 校验 codex 版本符合 pin（mac-launcher: codex 版本不符合 pin）
ACTUAL="$(codex --version 2>/dev/null | awk '{print $NF}')"
if [ "$ACTUAL" != "$PIN" ]; then
  echo "⚠️  警告：本机 codex 版本 $ACTUAL 与 pin $PIN 不一致，协议可能不兼容。" >&2
fi

# 2) 校验 sshd / 远程登录（mac-launcher: sshd 未开启时提示）
REMOTE_LOGIN="$(systemsetup -getremotelogin 2>/dev/null || echo 'Remote Login: Off')"
if echo "$REMOTE_LOGIN" | grep -qi 'Off'; then
  echo "❌ Mac 的“远程登录”(sshd) 未开启。" >&2
  echo "   请到 系统设置 → 通用 → 共享 → 远程登录 打开，或运行：" >&2
  echo "   sudo systemsetup -setremotelogin on" >&2
  exit 1
fi
```

- [x] **Step 2：确保受管 daemon 启用远程控制**

接上文，追加：经 `codex app-server daemon bootstrap --remote-control` 拉起受管 daemon 并启用远程控制；若 daemon 已运行则不重复创建，仅经 `enable-remote-control` 确保远程控制启用，并报告 daemon 状态/版本。**不**自起 `--listen ws://` 进程；iPad 经 SSH exec `codex app-server proxy` 桥接到 control socket（`~/.codex/app-server-control/app-server-control.sock`，仅属主可读）。

```bash
# 3) 确保受管 daemon 启用远程控制（mac-launcher: 正常启用远程控制 / daemon 已运行）
SOCK="$HOME/.codex/app-server-control/app-server-control.sock"
if codex app-server daemon version >/dev/null 2>&1; then
  echo "ℹ️  受管 daemon 已在运行，仅确保远程控制启用（不重复创建实例）。"
  codex app-server daemon enable-remote-control
else
  echo "ℹ️  受管 daemon 未运行，bootstrap 并启用远程控制。"
  codex app-server daemon bootstrap --remote-control
fi
DAEMON_VERSION="$(codex app-server daemon version 2>/dev/null || echo '未知')"
echo "  daemon 版本 : $DAEMON_VERSION"
echo "  control sock: $SOCK"
```

- [x] **Step 3：追加连接信息输出**

接上文，追加：打印 LAN IP / SSH 用户名，以及 iPad 经 SSH exec `codex app-server proxy` 接入的说明。daemon 已由 Step 2 拉起并在后台常驻，本脚本不再持有前台进程。

```bash
# 4) 输出连接信息（mac-launcher: 正常启用远程控制并输出连接信息）
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '未知')"
SSH_USER="$(whoami)"
echo "──────────────────────────────────────────"
echo " Codex 受管 daemon 已启用远程控制"
echo "  Mac LAN IP : $LAN_IP"
echo "  SSH 用户名 : $SSH_USER"
echo "  iPad 接入  : SSH 到 $SSH_USER@$LAN_IP，经 exec 通道运行"
echo "               codex app-server proxy（桥接到 control socket）"
echo "  control sock: $SOCK（仅属主可读，与桌面 app 共享受管 daemon）"
echo "──────────────────────────────────────────"
```

- [x] **Step 4：本地手动验证四个场景**

Run（在真实 Mac）：

```bash
chmod +x scripts/start-codex-appserver.sh
# 场景A 正常：
./scripts/start-codex-appserver.sh
```

Expected：打印 daemon 版本、control socket 路径、LAN IP / SSH 用户名，以及 iPad 经 exec `codex app-server proxy` 接入说明；受管 daemon 已启用远程控制。

```bash
# 场景C daemon 已运行：保持上一次已 bootstrap 的 daemon，再跑一次
./scripts/start-codex-appserver.sh
```

Expected：打印“受管 daemon 已在运行，仅确保远程控制启用（不重复创建实例）”，不重复 bootstrap，退出码 0。

> 场景 B（sshd 未开）与场景 D（版本不符）若当前 Mac 不满足触发条件，逐行 review 分支逻辑确认正确；在 E2E（Task 20）时再实测一次。

> **2026-06-11 实机验证发现（worktree 实跑）：**
> - 初版脚本用 `daemon version` 退出码两态判活有缺陷：`version` 报 `status:running` 只代表 control socket 上有 app-server 应答，**不保证它是 bootstrap 注册的“受管”实例**。本机 socket 实际被一个非受管 app-server（PID 51034，`~/.local/bin/codex app-server --listen unix://`，PPID=1，无 LaunchAgent）占用，导致 `enable-remote-control` 返回 `app server is running but is not managed by codex app-server daemon`（退出码 1，无副作用）。
> - 已修为三态：受管已运行→enable 成功；非受管占用→明确提示（列占用进程 + 给出退出占用或 `daemon restart --remote-control` 接管选项），**不自动 stop/restart 以免破坏 desktop**；无实例→bootstrap。
> - 场景 A/C 在“非受管占用”态下走的是新提示分支（符合 spec“不与 desktop app 的 app-server 冲突”）；待本机 socket 由受管 daemon 接管后即走 enable 成功分支，留待 Task 20 E2E 实测。
> - sshd 检测：`systemsetup -getremotelogin` 无 sudo 时输出 `You need administrator access... exiting!`（退出码 0，不匹配 On/Off），脚本正确回退到 `launchctl print system/com.openssh.sshd`（loaded → 视为开启）。本机 `pgrep -x sshd` 无常驻进程属 macOS 按需拉起的正常现象，launchctl 判据比 pgrep 更可靠。
> - 全程 desktop app-server 进程数 4→4 不变，受管 daemon 仍 running，零破坏。回退方式：`codex app-server daemon disable-remote-control`。

- [x] **Step 5：Commit**

```bash
git add scripts/start-codex-appserver.sh
git commit -m "feat(mac-launcher): one-shot script to bootstrap managed daemon with remote-control + preflight checks"
```

---

## Task 3：★SPIKE★ Citadel SSH exec 远端 codex app-server proxy + initialize 握手

**对应 spec：** `remote-connection/spec.md`「建立连接并完成握手」（spike 阶段只验证连通性，不做完整 UI）。

**这是 build 首步必须打通的最大未知风险**（设计 §11：Citadel 在 iPadOS 的 SSH exec 通道长连接 + 双向流式稳定性，及 `codex app-server proxy` 长连接稳定性）。先用最小可运行 demo 验证 Citadel 建 SSH → 开 exec 通道运行 `codex app-server proxy` → 在该通道 stdio 上完成 `initialize`→`initialized` 握手，再铺开 Task 6/7/8。

**Files:**
- Create: `ios/CodexRemote/Spike/SpikeView.swift`（临时验证视图，后续可删）
- Create: `ios/CodexRemote/Spike/SpikeRunner.swift`（临时验证逻辑）

- [x] **Step 1：写 spike 入口视图**

`ios/CodexRemote/Spike/SpikeView.swift` —— 一个有「连接」按钮和日志文本区的最简视图，把主机/端口/用户/密码硬编码为 `@State` 默认值（spike 期间可手填，不走 Keychain）：

```swift
import SwiftUI

struct SpikeView: View {
    @State private var host = ""
    @State private var sshPort = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var log = "未连接"
    @State private var runner = SpikeRunner()

    var body: some View {
        Form {
            TextField("Mac 主机/IP", text: $host).textInputAutocapitalization(.never)
            TextField("SSH 端口", text: $sshPort)
            TextField("SSH 用户名", text: $user).textInputAutocapitalization(.never)
            SecureField("SSH 密码", text: $password)
            Button("连接并握手") {
                Task {
                    log = "连接中…"
                    do {
                        log = try await runner.run(
                            host: host, sshPort: Int(sshPort) ?? 22,
                            user: user, password: password)
                    } catch { log = "失败：\(error)" }
                }
            }
            Text(log).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }
}
```

- [x] **Step 2：写 spike 运行逻辑（SSH + exec proxy + initialize）**

`ios/CodexRemote/Spike/SpikeRunner.swift` —— 用 Citadel 建 SSH，开 exec 通道运行远端命令 `codex app-server proxy`（它把 stdio 字节透明桥接到受管 daemon 的 control socket），在该 exec 通道的 stdout/stdin 上发送一条 `initialize` JSON-RPC（换行结尾），读回响应后发 `initialized` 通知：

```swift
import Foundation
import Citadel
import NIOCore

struct SpikeRunner {
    func run(host: String, sshPort: Int,
             user: String, password: String) async throws -> String {
        // 1) 建立 SSH 连接（密码鉴权，spike 简化）
        let client = try await SSHClient.connect(
            host: host, port: sshPort,
            authenticationMethod: .passwordBased(username: user, password: password),
            hostKeyValidator: .acceptAnything(), // 仅 spike：生产需固定/记录 host key
            reconnect: .never)

        // 2) exec 通道运行远端 codex app-server proxy。
        //    Citadel 暴露 executeCommandStream / withExecChannel 之类 API；以实际 API 为准。
        //    spike 目标：拿到该 exec 通道的可读写 stdio 流，承载 JSON-RPC。
        //    proxy 把 stdio 字节透明桥接到 ~/.codex/app-server-control/app-server-control.sock。

        // 3) 在该 exec 通道的 stdio 上发送 initialize（换行分隔 JSON）。
        //    关键验证点：initialize JSON 能写入 stdin 且能从 stdout 读回 initialize 响应。
        let initialize = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"CodexRemote-Spike","title":null,"version":"0.0.1"},"capabilities":null}}
        """
        // 经 exec 通道 stdin 写出 initialize（含换行），等首个响应（result 含 userAgent/codexHome）。
        let response = try await SpikeWire.sendAndAwaitFirstResponse(
            client: client, command: "codex app-server proxy", payload: initialize)
        // 发 initialized 通知（无 id，换行结尾）
        try await SpikeWire.send(
            payload: #"{"jsonrpc":"2.0","method":"initialized"}"#)

        return "握手成功 ✅\n响应：\(response.prefix(400))"
    }
}
```

> `SpikeWire` 是 spike 内联的极小帮手（一个 enum + 两个静态 async 方法），负责经 exec 通道 stdio 把字符串（换行结尾）写出并读回第一条完整 JSON。spike 不追求工程化，只要**真机上能跑通握手**。若 Citadel 的 exec 通道 API 命名/签名与上文不符，以 Citadel 当前版本源码/文档为准，但语义不变：建立 exec 通道运行 `codex app-server proxy` 并在其 stdio 上收发换行分隔 JSON。

- [x] **Step 3：把 spike 视图挂到 App 根（临时）** <!-- 已挂载 + 模拟器 BUILD SUCCEEDED (iPad-Test) 2026-06-11 -->

修改 `ios/CodexRemote/App/CodexRemoteApp.swift`，临时 `SpikeView()` 作根视图：

```swift
import SwiftUI

@main
struct CodexRemoteApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}
```

- [x] **Step 4：真机验证握手跑通（spike 唯一验收）** <!-- 2026-06-11 模拟器+真实SSH实测握手通过(SpikeIntegrationTests);物理设备差异待最终E2E -->

前置：在 Mac 上跑 `./scripts/start-codex-appserver.sh`（Task 2，确保受管 daemon 已启用远程控制）。
Run：Xcode 选**真实 iPad**（非模拟器，exec 通道长连接行为可能不同）→ 运行 → 在 SpikeView 填主机/端口/用户/密码 → 点「连接并握手」。
Expected：日志区显示「握手成功 ✅」并打印含 `userAgent` / `codexHome` 的 initialize 响应。

> 若失败：加载 **superpowers:systematic-debugging** skill 定位（Citadel SSH 是否建立？exec 通道是否成功运行 `codex app-server proxy`？JSON 是否被 app-server 接受？）。**根因未定位前不得继续 Task 6+**，因为后续传输层完全建立在此之上。

- [x] **Step 5：记录 spike 结论** <!-- 已记录于 SpikeRunner.swift 顶部：Citadel withExec 真实 API + 与伪代码偏差 -->

在 `ios/CodexRemote/Spike/SpikeRunner.swift` 顶部用一行注释记录验证结论（如：`// SPIKE PASS 2026-06-11: Citadel SSH exec codex app-server proxy + stdio initialize 握手在 iPad 真机跑通`），并记录任何 API 偏差，供 Task 6 复用。

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Spike ios/CodexRemote/App/CodexRemoteApp.swift
git commit -m "spike: verify Citadel SSH exec codex app-server proxy + stdio initialize handshake on iPad"
```

---

## Task 4：协议层 JSON-RPC 信封 Codable + 编解码

**对应 spec：** `remote-connection/spec.md`（JSON-RPC 2.0 承载）。可在 spike 进行时并行（纯 Swift + 单测，不需真机）。

字段形状取自真实 `protocol/schema/JSONRPCMessage.json`：`RequestId = string | int64`；Request 必含 `id`+`method`；Notification 无 `id`、含 `method`；Response 含 `id`+`result`；Error 含 `id`+`error{code,message,data?}`。

**Files:**
- Create: `ios/CodexRemote/RPC/JSONRPCEnvelope.swift`
- Test: `ios/CodexRemoteTests/JSONRPCEnvelopeTests.swift`

- [x] **Step 1：写失败测试（解码四类消息 + RequestId 双形）**

`ios/CodexRemoteTests/JSONRPCEnvelopeTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class JSONRPCEnvelopeTests: XCTestCase {
    func testDecodeResponseWithIntId() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .response(let r) = msg else { return XCTFail("应为 response") }
        XCTAssertEqual(r.id, .int(1))
    }
    func testDecodeNotificationNoId() throws {
        let json = #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"x":1}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .notification(let n) = msg else { return XCTFail("应为 notification") }
        XCTAssertEqual(n.method, "item/agentMessage/delta")
    }
    func testDecodeServerRequestStringId() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"item/commandExecution/requestApproval","params":{}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .request(let r) = msg else { return XCTFail("应为 request") }
        XCTAssertEqual(r.id, .string("abc"))
        XCTAssertEqual(r.method, "item/commandExecution/requestApproval")
    }
    func testDecodeError() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method not found"}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        guard case .error(let e) = msg else { return XCTFail("应为 error") }
        XCTAssertEqual(e.error.code, -32601)
    }
    func testEncodeRequestRoundTrip() throws {
        let req = JSONRPCRequest(id: .int(7), method: "thread/list",
                                 params: AnyCodable(["limit": 20]))
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(back.id, .int(7))
        XCTAssertEqual(back.method, "thread/list")
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/JSONRPCEnvelopeTests`
Expected：编译失败 / 测试失败，因 `JSONRPCMessage` 等类型尚未定义。

- [x] **Step 3：实现信封类型**

`ios/CodexRemote/RPC/JSONRPCEnvelope.swift`：

```swift
import Foundation

enum RequestId: Codable, Hashable {
    case string(String), int(Int64)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int64.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .int(let i): try c.encode(i) }
    }
}

struct JSONRPCRequest: Codable {
    var jsonrpc = "2.0"
    let id: RequestId
    let method: String
    var params: AnyCodable?
}

struct JSONRPCNotification: Codable {
    var jsonrpc = "2.0"
    let method: String
    var params: AnyCodable?
}

struct JSONRPCResponse: Codable {
    var jsonrpc = "2.0"
    let id: RequestId
    let result: AnyCodable
}

struct JSONRPCErrorBody: Codable { let code: Int; let message: String; var data: AnyCodable? }
struct JSONRPCError: Codable {
    var jsonrpc = "2.0"
    let id: RequestId
    let error: JSONRPCErrorBody
}

enum JSONRPCMessage: Decodable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case error(JSONRPCError)

    private enum Keys: String, CodingKey { case id, method, result, error }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        let hasId = c.contains(.id)
        if c.contains(.error) { self = .error(try JSONRPCError(from: d)) }
        else if c.contains(.method) {
            if hasId { self = .request(try JSONRPCRequest(from: d)) }
            else { self = .notification(try JSONRPCNotification(from: d)) }
        } else if c.contains(.result) {
            self = .response(try JSONRPCResponse(from: d))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                debugDescription: "无法识别的 JSON-RPC 消息"))
        }
    }
}
```

并实现 `AnyCodable`（类型擦除的 JSON 容器）于同文件或 `ios/CodexRemote/RPC/AnyCodable.swift`：

```swift
struct AnyCodable: Codable {
    let value: Any
    init(_ v: Any) { value = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int64.self) { value = i }
        else if let dbl = try? c.decode(Double.self) { value = dbl }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) {
            value = o.mapValues(\.value)
        } else { value = NSNull() }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int64: try c.encode(i)
        case let i as Int: try c.encode(Int64(i))
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}
```

- [x] **Step 4：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/JSONRPCEnvelopeTests`
Expected：全部 PASS。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/RPC ios/CodexRemoteTests/JSONRPCEnvelopeTests.swift
git commit -m "feat(rpc): JSON-RPC 2.0 envelope codable + decode dispatch (req/notif/resp/err)"
```

---

## Task 5：协议层 MVP 领域类型 Codable

**对应 spec：** 设计 §4。建模 MVP 用到的请求参数/响应/审批/通知类型。字段名与形状**严格取自** `protocol/ts`（见各文件），不要臆造。可与 spike/Task 4 并行。

**Files:**
- Create: `ios/CodexRemote/Protocol/InitializeTypes.swift`
- Create: `ios/CodexRemote/Protocol/ThreadTypes.swift`
- Create: `ios/CodexRemote/Protocol/TurnTypes.swift`
- Create: `ios/CodexRemote/Protocol/ApprovalTypes.swift`
- Create: `ios/CodexRemote/Protocol/Methods.swift`（方法名常量）
- Test: `ios/CodexRemoteTests/ProtocolTypesTests.swift`

- [x] **Step 1：写方法名常量**

`ios/CodexRemote/Protocol/Methods.swift`（取自设计 §4、真实 schema 的 enum title）：

```swift
enum RPCMethod {
    static let initialize = "initialize"
    static let initialized = "initialized"      // notification
    static let threadList = "thread/list"
    static let threadResume = "thread/resume"
    static let threadStart = "thread/start"
    static let turnStart = "turn/start"
    static let turnSteer = "turn/steer"
    static let turnInterrupt = "turn/interrupt"
    static let modelList = "model/list"
}

enum ServerRequestMethod {
    static let cmdApprovalV2 = "item/commandExecution/requestApproval"
    static let fileApprovalV2 = "item/fileChange/requestApproval"
    static let permsApprovalV2 = "item/permissions/requestApproval"
    static let execApprovalLegacy = "execCommandApproval"
    static let applyPatchApprovalLegacy = "applyPatchApproval"
}

enum ServerNotificationMethod {
    static let itemStarted = "item/started"
    static let itemCompleted = "item/completed"
    static let agentMessageDelta = "item/agentMessage/delta"
    static let commandOutputDelta = "item/commandExecution/outputDelta"
    static let fileChangePatchUpdated = "item/fileChange/patchUpdated"
    static let turnStarted = "turn/started"
    static let turnCompleted = "turn/completed"
    static let turnDiffUpdated = "turn/diff/updated"
    static let threadStarted = "thread/started"
    static let serverRequestResolved = "serverRequest/resolved"
    static let error = "error"
    static let warning = "warning"
}
```

- [x] **Step 2：写 initialize 类型（取自 InitializeParams.ts / InitializeResponse.ts / ClientInfo.ts）**

`ios/CodexRemote/Protocol/InitializeTypes.swift`：

```swift
import Foundation

struct ClientInfo: Codable {
    let name: String
    let title: String?
    let version: String
}

struct InitializeParams: Codable {
    let clientInfo: ClientInfo
    let capabilities: AnyCodable?   // InitializeCapabilities | null
}

struct InitializeResponse: Codable {
    let userAgent: String
    let codexHome: String          // AbsolutePathBuf
    let platformFamily: String
    let platformOs: String
}
```

- [x] **Step 3：写 thread 类型（取自 v2/Thread.ts, ThreadListParams.ts, ThreadListResponse.ts, ThreadResumeParams.ts, ThreadStartParams.ts, ThreadSourceKind.ts）**

`ios/CodexRemote/Protocol/ThreadTypes.swift`：

```swift
import Foundation

enum ReasoningEffort: String, Codable {
    case none, minimal, low, medium, high, xhigh
}

struct ThreadSummary: Codable, Identifiable {       // 取自 v2/Thread.ts 子集（MVP 用到的字段）
    let id: String
    let sessionId: String
    let preview: String
    let modelProvider: String
    let createdAt: Double
    let updatedAt: Double
    let cwd: String                                 // AbsolutePathBuf -> String
    let cliVersion: String
    let name: String?
}

struct ThreadListParams: Codable {
    var cursor: String?
    var limit: Int?
    // ThreadSourceKind: "cli"|"vscode"|"exec"|"appServer"|"subAgent"|...
    // 设计 §13 Open Question：默认 sourceKinds 是否含桌面 app（appServer）来源。
    // 为确保桌面会话可见，显式传入覆盖项（见 session-management 场景「桌面来源会话可见」）。
    var sourceKinds: [String]?
    var cwd: [String]?
}

struct ThreadListResponse: Codable {
    let data: [ThreadSummary]
    let nextCursor: String?
    let backwardsCursor: String?
}

struct ThreadResumeParams: Codable {
    let threadId: String
}

struct ThreadStartParams: Codable {
    var cwd: String?
    var model: String?
}
```

> 注：`ThreadSummary` 仅取 MVP 渲染左栏与分组所需字段（`id`/`preview`/`updatedAt`/`cwd`/`name`）。若 `thread/list` 实际返回 `ConversationSummary`（旧版）而非 `Thread`（v2），以连接实测的响应 JSON 为准调整字段；Task 12 录制 fixture 时核对。

- [x] **Step 4：写 turn 类型（取自 v2/TurnStartParams.ts, TurnSteerParams.ts, UserInput.ts, NonSteerableTurnKind.ts, ImageDetail.ts）**

`ios/CodexRemote/Protocol/TurnTypes.swift`：

```swift
import Foundation

enum ImageDetail: String, Codable { case high, original }

// 取自 v2/UserInput.ts：text | image | localImage | skill | mention
enum UserInput: Codable {
    case text(String)
    case image(url: String, detail: ImageDetail?)
    case localImage(path: String, detail: ImageDetail?)

    private enum Keys: String, CodingKey { case type, text, text_elements, url, detail, path }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
            try c.encode([String](), forKey: .text_elements)   // 必填，空数组
        case .image(let url, let d):
            try c.encode("image", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(d, forKey: .detail)
        case .localImage(let path, let d):
            try c.encode("localImage", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(d, forKey: .detail)
        }
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "image": self = .image(url: try c.decode(String.self, forKey: .url),
                                    detail: try c.decodeIfPresent(ImageDetail.self, forKey: .detail))
        case "localImage": self = .localImage(path: try c.decode(String.self, forKey: .path),
                                    detail: try c.decodeIfPresent(ImageDetail.self, forKey: .detail))
        default: self = .text("")
        }
    }
}

struct TurnStartParams: Codable {
    let threadId: String
    let input: [UserInput]
    var model: String?
    var effort: ReasoningEffort?        // 注意 v2 字段名是 effort，非 reasoningEffort
    var cwd: String?
}

struct TurnSteerParams: Codable {
    let threadId: String
    let input: [UserInput]
    let expectedTurnId: String
}

struct TurnInterruptParams: Codable {
    let threadId: String
}

enum NonSteerableTurnKind: String, Codable { case review, compact }
```

- [x] **Step 5：写审批类型（取自 schema：CommandExecutionRequestApprovalResponse.json, FileChangeRequestApprovalResponse.json, ExecCommandApprovalResponse.ts → ReviewDecision.ts, CommandExecutionRequestApprovalParams.json, FileChangeRequestApprovalParams.json）**

`ios/CodexRemote/Protocol/ApprovalTypes.swift` —— **关键：v2 与 legacy 的 decision 形状不同**。v2 用 `CommandExecutionApprovalDecision`（`accept` / `acceptForSession` / `{acceptWithExecpolicyAmendment:{execpolicy_amendment:[String]}}` / `decline` / `cancel`）；legacy 用 `ReviewDecision`（`approved` / `{approved_execpolicy_amendment:{proposed_execpolicy_amendment:[String]}}` / `approved_for_session` / `denied` / `abort`）：

```swift
import Foundation

// ===== v2 命令执行审批 decision（取自 CommandExecutionRequestApprovalResponse.json）=====
enum CommandExecutionApprovalDecision: Codable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(execpolicyAmendment: [String])
    case decline
    case cancel

    private enum AmendKeys: String, CodingKey { case acceptWithExecpolicyAmendment }
    private enum InnerKeys: String, CodingKey { case execpolicy_amendment }
    func encode(to e: Encoder) throws {
        switch self {
        case .accept: var c = e.singleValueContainer(); try c.encode("accept")
        case .acceptForSession: var c = e.singleValueContainer(); try c.encode("acceptForSession")
        case .decline: var c = e.singleValueContainer(); try c.encode("decline")
        case .cancel: var c = e.singleValueContainer(); try c.encode("cancel")
        case .acceptWithExecpolicyAmendment(let amend):
            var outer = e.container(keyedBy: AmendKeys.self)
            var inner = outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .acceptWithExecpolicyAmendment)
            try inner.encode(amend, forKey: .execpolicy_amendment)
        }
    }
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) {
            switch s {
            case "accept": self = .accept
            case "acceptForSession": self = .acceptForSession
            case "decline": self = .decline
            case "cancel": self = .cancel
            default: self = .decline
            }
            return
        }
        let outer = try d.container(keyedBy: AmendKeys.self)
        let inner = try outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .acceptWithExecpolicyAmendment)
        self = .acceptWithExecpolicyAmendment(
            execpolicyAmendment: try inner.decode([String].self, forKey: .execpolicy_amendment))
    }
}

struct CommandExecutionApprovalResponse: Codable {
    let decision: CommandExecutionApprovalDecision
}

// ===== v2 文件改动审批 decision（取自 FileChangeRequestApprovalResponse.json）=====
enum FileChangeApprovalDecision: String, Codable {
    case accept, acceptForSession, decline, cancel
}
struct FileChangeApprovalResponse: Codable { let decision: FileChangeApprovalDecision }

// ===== legacy ReviewDecision（取自 ReviewDecision.ts）=====
enum ReviewDecision: Codable {
    case approved
    case approvedExecpolicyAmendment(proposed: [String])
    case approvedForSession
    case denied
    case abort

    private enum AmendKeys: String, CodingKey { case approved_execpolicy_amendment }
    private enum InnerKeys: String, CodingKey { case proposed_execpolicy_amendment }
    func encode(to e: Encoder) throws {
        switch self {
        case .approved: var c = e.singleValueContainer(); try c.encode("approved")
        case .approvedForSession: var c = e.singleValueContainer(); try c.encode("approved_for_session")
        case .denied: var c = e.singleValueContainer(); try c.encode("denied")
        case .abort: var c = e.singleValueContainer(); try c.encode("abort")
        case .approvedExecpolicyAmendment(let p):
            var outer = e.container(keyedBy: AmendKeys.self)
            var inner = outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .approved_execpolicy_amendment)
            try inner.encode(p, forKey: .proposed_execpolicy_amendment)
        }
    }
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) {
            switch s {
            case "approved": self = .approved
            case "approved_for_session": self = .approvedForSession
            case "denied": self = .denied
            case "abort", "timed_out": self = .abort
            default: self = .denied
            }
            return
        }
        let outer = try d.container(keyedBy: AmendKeys.self)
        let inner = try outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .approved_execpolicy_amendment)
        self = .approvedExecpolicyAmendment(
            proposed: try inner.decode([String].self, forKey: .proposed_execpolicy_amendment))
    }
}
struct ExecCommandApprovalResponse: Codable { let decision: ReviewDecision }

// ===== 审批请求参数（取自 CommandExecutionRequestApprovalParams.json 等，MVP 子集）=====
struct CommandExecutionApprovalParams: Codable {
    let threadId: String
    let turnId: String
    let itemId: String
    let approvalId: String?
    let command: String?
    let cwd: String?
    let proposedExecpolicyAmendment: [String]?
}

struct FileChangeApprovalParams: Codable {
    let threadId: String
    let turnId: String?
    let itemId: String?
    // 文件改动明细：MVP 用 AnyCodable 承载 patch/diff，Task 18 渲染时取所需字段
    let changes: AnyCodable?
}
```

- [x] **Step 6：写解码/编码往返测试（用真实 schema 形状）**

`ios/CodexRemoteTests/ProtocolTypesTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class ProtocolTypesTests: XCTestCase {
    func testV2AcceptWithAmendmentEncodes() throws {
        let d = CommandExecutionApprovalDecision
            .acceptWithExecpolicyAmendment(execpolicyAmendment: ["git", "status"])
        let data = try JSONEncoder().encode(CommandExecutionApprovalResponse(decision: d))
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(s.contains("execpolicy_amendment"))
    }
    func testV2DeclineEncodesBareString() throws {
        let data = try JSONEncoder().encode(CommandExecutionApprovalResponse(decision: .decline))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"decision":"decline"}"#)
    }
    func testLegacyReviewDecisionApprovedForSession() throws {
        let data = try JSONEncoder().encode(ExecCommandApprovalResponse(decision: .approvedForSession))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"decision":"approved_for_session"}"#)
    }
    func testUserInputTextEncodesElements() throws {
        let data = try JSONEncoder().encode([UserInput.text("hi")])
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""type":"text""#))
        XCTAssertTrue(s.contains("text_elements"))
    }
    func testTurnStartParamsUsesEffortKey() throws {
        let p = TurnStartParams(threadId: "t1", input: [.text("hi")],
                                model: "gpt-5", effort: .high, cwd: nil)
        let s = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""effort":"high""#))
    }
    func testInitializeResponseDecodes() throws {
        let json = #"{"userAgent":"codex","codexHome":"/Users/x/.codex","platformFamily":"unix","platformOs":"macos"}"#
        let r = try JSONDecoder().decode(InitializeResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(r.platformOs, "macos")
    }
}
```

- [x] **Step 7：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ProtocolTypesTests`
Expected：全部 PASS。

- [x] **Step 8：Commit**

```bash
git add ios/CodexRemote/Protocol ios/CodexRemoteTests/ProtocolTypesTests.swift
git commit -m "feat(protocol): MVP codable types (initialize/thread/turn/approval) from schema"
```

---

## Task 6：传输层 SSHClient（封装 spike 成果为可复用 actor）

**对应 spec：** `remote-connection/spec.md`「建立连接并完成握手」「SSH 鉴权失败」「app-server 不可达」。依赖 Task 3 spike 结论与 Task 5 类型。

**Files:**
- Create: `ios/CodexRemote/Transport/SSHClient.swift`
- Create: `ios/CodexRemote/Transport/TransportError.swift`

- [x] **Step 1：定义传输错误类型**

`ios/CodexRemote/Transport/TransportError.swift`：

```swift
import Foundation

enum TransportError: Error, Equatable {
    case sshAuthFailed(String)        // remote-connection: SSH 鉴权失败
    case appServerUnreachable         // remote-connection: app-server 不可达
    case proxyFailed(String)          // exec codex app-server proxy 失败
    case channelClosed(reason: String?)
    case notConnected
}
```

- [x] **Step 2：实现 SSHClient actor（建连 + exec codex app-server proxy，复用 spike 中已验证的 Citadel API）**

`ios/CodexRemote/Transport/SSHClient.swift`：

```swift
import Foundation
import Citadel
import NIOCore

enum SSHAuth {
    case password(user: String, password: String)
    case privateKey(user: String, pem: String, passphrase: String?)
}

actor SSHClientWrapper {
    private var client: Citadel.SSHClient?

    /// 建立 SSH 连接并开 exec 通道运行远端 `codex app-server proxy`，
    /// 返回该 exec 通道的双向字节流（stdin 写、stdout 读）。
    /// 鉴权失败 → TransportError.sshAuthFailed；连接成功但 proxy 不可用 → appServerUnreachable。
    func connect(host: String, sshPort: Int,
                 auth: SSHAuth) async throws -> ExecChannel {
        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let u, let p): method = .passwordBased(username: u, password: p)
        case .privateKey(let u, let pem, let pass):
            method = .privateKey(username: u,
                                 privateKey: try .init(sshRsa: pem, decryptionKey: pass?.data(using: .utf8)))
        }
        do {
            client = try await Citadel.SSHClient.connect(
                host: host, port: sshPort,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(),   // TODO Task 11：固定/记录 host key
                reconnect: .never)
        } catch {
            throw TransportError.sshAuthFailed("\(error)")
        }
        guard let client else { throw TransportError.notConnected }
        do {
            // 复用 spike 已验证的 Citadel exec API：运行 codex app-server proxy，
            // 拿到该通道的 stdin/stdout 双向字节流（proxy 桥接到 control socket）。
            return try await openProxyExecChannel(client, command: "codex app-server proxy")
        } catch {
            throw TransportError.appServerUnreachable
        }
    }

    func close() async {
        try? await client?.close()
        client = nil
    }
}
```

> 以 Task 3 spike 中确认可用的 Citadel exec API 形状为准（`ExecChannel` / `openProxyExecChannel` 是占位名，按 spike 实际接口落地）。此处仅负责建 SSH + 拿到 exec 通道的 stdio 双向流；换行分隔 JSON 的帧收发在 Task 7。

- [x] **Step 3：编译验证**

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功（actor 真机连通在 Task 20 E2E 验证，单测覆盖错误映射在 Task 10 mock 层）。

- [x] **Step 4：Commit**

```bash
git add ios/CodexRemote/Transport/SSHClient.swift ios/CodexRemote/Transport/TransportError.swift
git commit -m "feat(transport): SSHClient actor with exec codex app-server proxy channel + typed errors"
```

---

## Task 7：传输层 ProxyChannel（actor，exec stdio 上换行分隔 JSON 帧收发）

**对应 spec：** `remote-connection/spec.md`（JSON-RPC over stdio 承载）。依赖 Task 6 的 exec 通道。

定义一个传输抽象协议，便于 Task 8/10 用 mock 替身做单元测试（设计 §10）。

**Files:**
- Create: `ios/CodexRemote/Transport/MessageTransport.swift`（抽象协议）
- Create: `ios/CodexRemote/Transport/ProxyChannel.swift`
- Test: `ios/CodexRemoteTests/MockTransport.swift`（测试替身，供后续任务复用）

- [x] **Step 1：定义传输抽象协议**

`ios/CodexRemote/Transport/MessageTransport.swift`：

```swift
import Foundation

/// 收发原始 JSON 文本帧的抽象。真实实现走 exec proxy 的 stdio（换行分隔），测试用 mock。
protocol MessageTransport: Sendable {
    func send(_ text: String) async throws
    /// 持续产出收到的每一条 JSON 文本帧，直到连接关闭。
    func incoming() -> AsyncThrowingStream<String, Error>
    func close() async
}
```

- [x] **Step 2：实现 ProxyChannel actor**

`ios/CodexRemote/Transport/ProxyChannel.swift` —— 在 Task 6 的 exec 通道 stdio 上做**换行分隔 JSON 帧**的收发：`send` 把一条完整 JSON 加换行写入 stdin；`incoming()` 从 stdout 按换行切分、每条完整 JSON 文本 yield 一次。按 spike 结论接线读写：

```swift
import Foundation
import NIOCore

actor ProxyChannel: MessageTransport {
    private let channel: ExecChannel
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    init(channel: ExecChannel) { self.channel = channel }

    func send(_ text: String) async throws {
        // 换行分隔 JSON 帧：写入一条完整 JSON 加换行到 exec 通道 stdin。
        try await channel.writeStdin(text + "\n")
    }

    func incoming() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            // 从 exec 通道 stdout 持续读字节，按 "\n" 切分缓冲，
            // 每收到一条完整 JSON 行就 yield 出去。具体读取按 spike 验证可行的方式实现。
        }
    }

    func close() async {
        continuation?.finish()
        await channel.close()
    }
}
```

> stdio 帧的具体读写（字节读取、按换行分帧、不完整行的缓冲）以 spike 中真机验证可行的实现为准。关键契约：`send` 发一条完整 JSON（自动补换行），`incoming()` 每条完整 JSON 行 yield 一次。`ExecChannel` 是占位名，以 Task 6 落地的 exec 通道类型为准。

- [x] **Step 3：写可复用的 MockTransport（测试替身）**

`ios/CodexRemoteTests/MockTransport.swift` —— 供 Task 8/9/10/18/19 重放录制 fixture：

```swift
import Foundation
@testable import CodexRemote

actor MockTransport: MessageTransport {
    private(set) var sent: [String] = []
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    let stream: AsyncThrowingStream<String, Error>

    init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }
    func send(_ text: String) async throws { sent.append(text) }
    func incoming() -> AsyncThrowingStream<String, Error> { stream }
    func close() async { continuation?.finish() }

    /// 测试驱动：模拟服务端推来一条 JSON 帧。
    func feed(_ json: String) { continuation?.yield(json) }
    func feedFile(_ name: String, bundle: Bundle = .module) throws {
        let url = bundle.url(forResource: name, withExtension: "json")!
        try feed(String(contentsOf: url, encoding: .utf8))
    }
}
```

- [x] **Step 4：编译验证**

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/Transport/MessageTransport.swift ios/CodexRemote/Transport/ProxyChannel.swift ios/CodexRemoteTests/MockTransport.swift
git commit -m "feat(transport): MessageTransport protocol + ProxyChannel (newline-delimited JSON over exec stdio) + MockTransport"
```

---

## Task 8：JSON-RPC 层 JSONRPCClient（id 关联 + 通知流 + server 请求分发）

**对应 spec：** `remote-connection/spec.md` + `approval-flow/spec.md`（server→client 请求需注册处理器）。依赖 Task 4/7。

**Files:**
- Create: `ios/CodexRemote/RPC/JSONRPCClient.swift`
- Test: `ios/CodexRemoteTests/JSONRPCClientTests.swift`

- [x] **Step 1：写失败测试（请求-响应 id 关联 + 通知流 + server 请求分发）**

`ios/CodexRemoteTests/JSONRPCClientTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class JSONRPCClientTests: XCTestCase {
    func testRequestResolvesByMatchingId() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        async let result: AnyCodable = client.send(method: "thread/list", params: AnyCodable(["limit": 1]))
        // 取出客户端发出的 id 回填一条响应
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = await mock.sent.first!
        XCTAssertTrue(sent.contains("thread/list"))
        await mock.feed(#"{"jsonrpc":"2.0","id":1,"result":{"data":[]}}"#)
        let r = try await result
        XCTAssertNotNil(r)
    }

    func testNotificationsFlowToStream() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let exp = expectation(description: "notif")
        Task {
            for await n in client.notifications() {
                if n.method == "item/agentMessage/delta" { exp.fulfill(); break }
            }
        }
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"text":"hi"}}"#)
        await fulfillment(of: [exp], timeout: 1)
    }

    func testServerRequestDispatchedToHandler() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.setServerRequestHandler { req in
            XCTAssertEqual(req.method, "item/commandExecution/requestApproval")
            return AnyCodable(["decision": "decline"])   // 回 v2 decline
        }
        await client.start()
        await mock.feed(#"{"jsonrpc":"2.0","id":"r1","method":"item/commandExecution/requestApproval","params":{}}"#)
        try await Task.sleep(nanoseconds: 100_000_000)
        let replied = await mock.sent.last!
        XCTAssertTrue(replied.contains(#""id":"r1""#))
        XCTAssertTrue(replied.contains("decline"))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/JSONRPCClientTests`
Expected：编译失败（`JSONRPCClient` 未定义）。

- [x] **Step 3：实现 JSONRPCClient actor**

`ios/CodexRemote/RPC/JSONRPCClient.swift`：

```swift
import Foundation

actor JSONRPCClient {
    typealias ServerRequestHandler = @Sendable (JSONRPCRequest) async -> AnyCodable

    private let transport: MessageTransport
    private var nextId: Int64 = 0
    private var pending: [RequestId: CheckedContinuation<AnyCodable, Error>] = [:]
    private var serverRequestHandler: ServerRequestHandler?
    private var notifContinuation: AsyncStream<JSONRPCNotification>.Continuation?
    private let notifStream: AsyncStream<JSONRPCNotification>
    private var pump: Task<Void, Never>?

    init(transport: MessageTransport) {
        self.transport = transport
        var cont: AsyncStream<JSONRPCNotification>.Continuation!
        notifStream = AsyncStream { cont = $0 }
        notifContinuation = cont
    }

    func notifications() -> AsyncStream<JSONRPCNotification> { notifStream }
    func setServerRequestHandler(_ h: @escaping ServerRequestHandler) { serverRequestHandler = h }

    func start() {
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in await self.transport.incoming() {
                    await self.handle(line)
                }
            } catch {
                await self.failAllPending(error)
            }
        }
    }

    func send(method: String, params: AnyCodable?) async throws -> AnyCodable {
        nextId += 1
        let id = RequestId.int(nextId)
        let req = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(req)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await transport.send(String(data: data, encoding: .utf8)!) }
                catch { pending[id] = nil; cont.resume(throwing: error) }
            }
        }
    }

    func notify(method: String, params: AnyCodable?) async throws {
        let n = JSONRPCNotification(method: method, params: params)
        let data = try JSONEncoder().encode(n)
        try await transport.send(String(data: data, encoding: .utf8)!)
    }

    private func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
        switch msg {
        case .response(let r):
            pending.removeValue(forKey: r.id)?.resume(returning: r.result)
        case .error(let e):
            pending.removeValue(forKey: e.id)?
                .resume(throwing: TransportError.proxyFailed(e.error.message))
        case .notification(let n):
            notifContinuation?.yield(n)
        case .request(let req):
            let result = await serverRequestHandler?(req) ?? AnyCodable(NSNull())
            let resp = JSONRPCResponse(id: req.id, result: result)
            if let out = try? JSONEncoder().encode(resp) {
                try? await transport.send(String(data: out, encoding: .utf8)!)
            }
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}
```

- [x] **Step 4：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/JSONRPCClientTests`
Expected：全部 PASS。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/RPC/JSONRPCClient.swift ios/CodexRemoteTests/JSONRPCClientTests.swift
git commit -m "feat(rpc): JSONRPCClient actor (id correlation, notification stream, server-request dispatch)"
```

---

## Task 9：归约层 ThreadReducer（notification → 会话状态）

**对应 spec：** `conversation-streaming/spec.md`（流式正文/命令输出/文件 diff 的归约）。依赖 Task 5。纯函数，最适合 fixture 单测（设计 §10）。

**Files:**
- Create: `ios/CodexRemote/Domain/ConversationModels.swift`
- Create: `ios/CodexRemote/Domain/ThreadReducer.swift`
- Create: `ios/CodexRemoteTests/Fixtures/`（录制的合成事件序列 .json）
- Test: `ios/CodexRemoteTests/ThreadReducerTests.swift`

- [x] **Step 1：定义会话领域模型**

`ios/CodexRemote/Domain/ConversationModels.swift`：

```swift
import Foundation

enum ConversationItem: Identifiable, Equatable {
    case userMessage(id: String, text: String)
    case agentMessage(id: String, text: String)              // 随 delta 累加
    case commandExecution(id: String, command: String, output: String, finished: Bool)
    case fileChange(id: String, file: String, added: Int, removed: Int, diff: String)

    var id: String {
        switch self {
        case .userMessage(let i, _), .agentMessage(let i, _),
             .commandExecution(let i, _, _, _), .fileChange(let i, _, _, _, _): return i
        }
    }
}

struct ConversationState: Equatable {
    var threadId: String
    var items: [ConversationItem] = []
    var activeTurnId: String?
    var activeTurnKind: NonSteerableTurnKind?    // 非 nil 表示不可 steer
    var isTurnRunning: Bool { activeTurnId != nil }
}
```

- [x] **Step 2：写失败测试（用合成事件序列驱动 reducer）**

先准备 fixture `ios/CodexRemoteTests/Fixtures/agentDeltaSequence.json`（一组按行的 notification）：

```json
[
  {"method":"turn/started","params":{"turnId":"T1"}},
  {"method":"item/started","params":{"itemId":"I1","itemType":"agentMessage"}},
  {"method":"item/agentMessage/delta","params":{"itemId":"I1","delta":"Hel"}},
  {"method":"item/agentMessage/delta","params":{"itemId":"I1","delta":"lo"}},
  {"method":"item/completed","params":{"itemId":"I1"}},
  {"method":"turn/completed","params":{"turnId":"T1"}}
]
```

`ios/CodexRemoteTests/ThreadReducerTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class ThreadReducerTests: XCTestCase {
    func testAgentDeltaAccumulates() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        for n in try loadNotifs("agentDeltaSequence") { reducer.apply(n, to: &state) }
        guard case .agentMessage(_, let text)? = state.items.first else {
            return XCTFail("应有 agentMessage")
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertFalse(state.isTurnRunning)   // turn/completed 后不再运行
    }

    func testTurnStartedMarksRunning() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/started", ["turnId": "T9"]), to: &state)
        XCTAssertEqual(state.activeTurnId, "T9")
        XCTAssertTrue(state.isTurnRunning)
    }

    func testCommandOutputDeltaAppends() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["itemId":"C1","itemType":"commandExecution","command":"ls"]), to: &state)
        reducer.apply(notif("item/commandExecution/outputDelta", ["itemId":"C1","delta":"a.txt\n"]), to: &state)
        reducer.apply(notif("item/commandExecution/outputDelta", ["itemId":"C1","delta":"b.txt\n"]), to: &state)
        guard case .commandExecution(_, _, let out, _)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(out, "a.txt\nb.txt\n")
    }

    // helpers
    private func notif(_ m: String, _ p: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(p))
    }
    private func loadNotifs(_ name: String) throws -> [JSONRPCNotification] {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        let arr = try JSONDecoder().decode([JSONRPCNotification].self, from: Data(contentsOf: url))
        return arr
    }
}
```

- [x] **Step 3：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ThreadReducerTests`
Expected：编译失败（`ThreadReducer` 未定义）。

- [x] **Step 4：实现 ThreadReducer**

`ios/CodexRemote/Domain/ThreadReducer.swift`：

```swift
import Foundation

struct ThreadReducer {
    func apply(_ n: JSONRPCNotification, to state: inout ConversationState) {
        let p = (n.params?.value as? [String: Any]) ?? [:]
        switch n.method {
        case ServerNotificationMethod.turnStarted:
            state.activeTurnId = p["turnId"] as? String
            if let kind = p["kind"] as? String { state.activeTurnKind = NonSteerableTurnKind(rawValue: kind) }
        case ServerNotificationMethod.turnCompleted:
            state.activeTurnId = nil; state.activeTurnKind = nil
        case ServerNotificationMethod.itemStarted:
            guard let id = p["itemId"] as? String else { return }
            switch p["itemType"] as? String {
            case "agentMessage": upsert(.agentMessage(id: id, text: ""), &state)
            case "commandExecution":
                upsert(.commandExecution(id: id, command: p["command"] as? String ?? "",
                                         output: "", finished: false), &state)
            case "fileChange":
                upsert(.fileChange(id: id, file: p["file"] as? String ?? "",
                                   added: 0, removed: 0, diff: ""), &state)
            default: break
            }
        case ServerNotificationMethod.agentMessageDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateAgent(id: id, append: d, &state)
        case ServerNotificationMethod.commandOutputDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateCommand(id: id, append: d, &state)
        case ServerNotificationMethod.fileChangePatchUpdated, ServerNotificationMethod.turnDiffUpdated:
            if let id = p["itemId"] as? String { mutateFile(id: id, params: p, &state) }
        case ServerNotificationMethod.itemCompleted:
            if let id = p["itemId"] as? String { finishCommand(id: id, &state) }
        default: break
        }
    }

    private func upsert(_ item: ConversationItem, _ s: inout ConversationState) {
        if !s.items.contains(where: { $0.id == item.id }) { s.items.append(item) }
    }
    private func mutateAgent(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .agentMessage(_, let t) = s.items[i] else { return }
        s.items[i] = .agentMessage(id: id, text: t + append)
    }
    private func mutateCommand(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, let f) = s.items[i] else { return }
        s.items[i] = .commandExecution(id: id, command: c, output: o + append, finished: f)
    }
    private func mutateFile(id: String, params: [String: Any], _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .fileChange(_, let f, _, _, _) = s.items[i] else { return }
        s.items[i] = .fileChange(id: id, file: f,
                                 added: params["added"] as? Int ?? 0,
                                 removed: params["removed"] as? Int ?? 0,
                                 diff: params["diff"] as? String ?? "")
    }
    private func finishCommand(id: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, _) = s.items[i] else { return }
        s.items[i] = .commandExecution(id: id, command: c, output: o, finished: true)
    }
}
```

> 字段名（`itemId`/`delta`/`itemType`/`command`/`kind`）按真实 `ServerNotification.json` 核对；Task 20 录制真实帧后若有出入，回此处校正（这是设计 §13 留待 build 确认项之一）。

- [x] **Step 5：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ThreadReducerTests`
Expected：全部 PASS。

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Domain ios/CodexRemoteTests/ThreadReducerTests.swift ios/CodexRemoteTests/Fixtures
git commit -m "feat(domain): ThreadReducer reduces notifications to conversation state (+ fixture tests)"
```

---

## Task 10：状态层 ConnectionStore（连接生命周期状态机 + 重连）

**对应 spec：** `remote-connection/spec.md`「建立连接并完成握手」「SSH 鉴权失败」「app-server 不可达」「连接中断后自动重连」「重连期间的用户可见状态」。依赖 Task 6/7/8。

**Files:**
- Create: `ios/CodexRemote/Stores/ConnectionStore.swift`
- Test: `ios/CodexRemoteTests/ConnectionStoreTests.swift`

- [x] **Step 1：写失败测试（状态机转移 + 握手 + 鉴权失败映射）**

`ios/CodexRemoteTests/ConnectionStoreTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class ConnectionStoreTests: XCTestCase {
    func testHandshakeReachesReady() async throws {
        let mock = MockTransport()
        let store = ConnectionStore(transportFactory: { _ in mock })
        // 服务端在收到 initialize 后回响应
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await mock.feed(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
        }
        try await store.connect(config: .stub)
        XCTAssertEqual(store.phase, .ready)
        // 发出了 initialize 与 initialized
        let sent = await mock.sent
        XCTAssertTrue(sent.contains { $0.contains("initialize") })
        XCTAssertTrue(sent.contains { $0.contains(#""method":"initialized""#) })
    }

    func testReconnectingPhaseVisibleOnDrop() async throws {
        let mock = MockTransport()
        let store = ConnectionStore(transportFactory: { _ in mock })
        Task { try? await Task.sleep(nanoseconds: 30_000_000)
               await mock.feed(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"c","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#) }
        try await store.connect(config: .stub)
        await mock.close()                     // 模拟断线
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.phase, .reconnecting)   // remote-connection: 重连中可见
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ConnectionStoreTests`
Expected：编译失败（`ConnectionStore` 未定义）。

- [x] **Step 3：实现 ConnectionStore（@Observable 状态机，设计 §7）**

`ios/CodexRemote/Stores/ConnectionStore.swift`：

```swift
import Foundation
import Observation

struct ConnectionConfig: Sendable {
    var host: String; var sshPort: Int; var auth: SSHAuth
    static var stub: ConnectionConfig {
        .init(host: "x", sshPort: 22, auth: .password(user: "u", password: "p"))
    }
}

enum ConnectionPhase: Equatable {
    case disconnected, sshConnecting, execProxy, initializing, ready
    case reconnecting, failed(String)
}

@Observable
@MainActor
final class ConnectionStore {
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var serverInfo: InitializeResponse?
    var rpc: JSONRPCClient?

    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport
    private var config: ConnectionConfig?
    private var reconnectAttempts = 0

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.transportFactory = transportFactory
    }

    func connect(config: ConnectionConfig) async throws {
        self.config = config
        try await establish(config)
    }

    private func establish(_ config: ConnectionConfig) async throws {
        phase = .execProxy
        let transport = try await transportFactory(config)     // 工厂内部含 SSH + exec codex app-server proxy
        let client = JSONRPCClient(transport: transport)
        await client.start()
        self.rpc = client
        phase = .initializing
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
            capabilities: nil)
        let result = try await client.send(method: RPCMethod.initialize,
                                           params: try encode(params))
        serverInfo = try decode(InitializeResponse.self, from: result)
        try await client.notify(method: RPCMethod.initialized, params: nil)
        phase = .ready
        reconnectAttempts = 0
        observeDisconnect(client)
    }

    private func observeDisconnect(_ client: JSONRPCClient) {
        Task { [weak self] in
            for await _ in await client.notifications() { }   // 流结束=断线
            guard let self, let config = self.config else { return }
            await MainActor.run { self.phase = .reconnecting }
            await self.reconnectWithBackoff(config)
        }
    }

    private func reconnectWithBackoff(_ config: ConnectionConfig) async {
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30)   // 指数退避，封顶 30s
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        do { try await establish(config) }       // 重新 initialize；线程恢复交 ConversationStore
        catch { phase = .reconnecting; await reconnectWithBackoff(config) }
    }

    // encode/decode helpers
    private func encode<T: Encodable>(_ v: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }
    private func decode<T: Decodable>(_ t: T.Type, from a: AnyCodable) throws -> T {
        let data = try JSONEncoder().encode(a)
        return try JSONDecoder().decode(t, from: data)
    }
}
```

- [x] **Step 4：把真实工厂接线（SSH → exec codex app-server proxy）放在 App 装配处**

在 `ios/CodexRemote/App/` 增加一个装配函数（生产用），把 Task 6/7 组合成 `transportFactory`：

```swift
// ios/CodexRemote/App/LiveTransport.swift
import Foundation

func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    // Task 6/7 后：SSHClientWrapper 为 enum，connect 直接返回已 start 的 ProxyChannel（即 MessageTransport）。
    try await SSHClientWrapper.connect(
        host: config.host, sshPort: config.sshPort, auth: config.auth)
}
```

- [x] **Step 5：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ConnectionStoreTests`
Expected：全部 PASS。

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemote/App/LiveTransport.swift ios/CodexRemoteTests/ConnectionStoreTests.swift
git commit -m "feat(stores): ConnectionStore lifecycle state machine + initialize handshake + backoff reconnect"
```

---

## Task 11：凭证安全存储（KeychainStore）+ 连接配置界面

**对应 spec：** `remote-connection/spec.md`「凭证存入 Keychain」+「建立连接并完成握手」（用户输入连接信息）。依赖 Task 10。

**Files:**
- Create: `ios/CodexRemote/Security/KeychainStore.swift`
- Create: `ios/CodexRemote/Views/ConnectionConfigView.swift`
- Test: `ios/CodexRemoteTests/KeychainStoreTests.swift`

- [x] **Step 1：写失败测试（存取删，不落明文偏好）**

`ios/CodexRemoteTests/KeychainStoreTests.swift`：

```swift
import XCTest
@testable import CodexRemote

final class KeychainStoreTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let store = KeychainStore(service: "com.codexremote.test")
        try store.save("secret-key", for: "ssh-credential")
        XCTAssertEqual(try store.load("ssh-credential"), "secret-key")
        try store.delete("ssh-credential")
        XCTAssertNil(try store.load("ssh-credential"))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/KeychainStoreTests`
Expected：编译失败（`KeychainStore` 未定义）。

- [x] **Step 3：实现 KeychainStore**

`ios/CodexRemote/Security/KeychainStore.swift`：

```swift
import Foundation
import Security

struct KeychainStore {
    let service: String

    func save(_ value: String, for account: String) throws {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
    }
    func load(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw KeychainError.os(status) }
        return String(data: d, encoding: .utf8)
    }
    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.os(status) }
    }
    enum KeychainError: Error { case os(OSStatus) }
}
```

- [x] **Step 4：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/KeychainStoreTests`
Expected：PASS。

- [x] **Step 5：实现连接配置界面**

`ios/CodexRemote/Views/ConnectionConfigView.swift` —— 主机/端口/SSH 用户/密钥或密码输入；非敏感项（主机/端口/用户）存 `UserDefaults`，**私钥/密码经 KeychainStore 存储**；点击连接调用 `ConnectionStore.connect`，并把 `.sshAuthFailed`/`.appServerUnreachable` 渲染为明确错误文案：

```swift
import SwiftUI

struct ConnectionConfigView: View {
    @Environment(ConnectionStore.self) private var connection
    private let keychain = KeychainStore(service: "com.codexremote.ssh")
    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var sshPort = "22"
    @State private var user = UserDefaults.standard.string(forKey: "sshUser") ?? ""
    @State private var secret = ""
    @State private var usePrivateKey = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Mac 连接") {
                TextField("主机/IP", text: $host).textInputAutocapitalization(.never)
                TextField("SSH 端口", text: $sshPort)
                TextField("SSH 用户名", text: $user).textInputAutocapitalization(.never)
                Toggle("使用私钥", isOn: $usePrivateKey)
                SecureField(usePrivateKey ? "私钥 PEM" : "密码", text: $secret)
            }
            if let e = errorText { Text(e).foregroundStyle(.red) }
            Button("连接") { Task { await connect() } }
        }
    }

    private func connect() async {
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(user, forKey: "sshUser")
        try? keychain.save(secret, for: "ssh-credential")     // 敏感项入 Keychain
        let auth: SSHAuth = usePrivateKey
            ? .privateKey(user: user, pem: secret, passphrase: nil)
            : .password(user: user, password: secret)
        let cfg = ConnectionConfig(host: host, sshPort: Int(sshPort) ?? 22, auth: auth)
        do { try await connection.connect(config: cfg); errorText = nil }
        catch TransportError.sshAuthFailed(let m) { errorText = "SSH 鉴权失败：\(m)" }
        catch TransportError.appServerUnreachable { errorText = "app-server 不可达，请检查 Mac 端启动脚本是否已启用受管 daemon 远程控制。" }
        catch { errorText = "连接失败：\(error)" }
    }
}
```

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Security ios/CodexRemote/Views/ConnectionConfigView.swift ios/CodexRemoteTests/KeychainStoreTests.swift
git commit -m "feat(security): KeychainStore for SSH credentials + connection config view with typed errors"
```

---

## Task 12：状态层 ProjectsStore（thread/list 按 cwd 分组 + 待批准徽标）

**对应 spec：** `session-management/spec.md`「左栏按项目分组展示对话」「桌面来源会话可见」+「显示等待批准徽标」。依赖 Task 8/10。

**Files:**
- Create: `ios/CodexRemote/Stores/ProjectsStore.swift`
- Test: `ios/CodexRemoteTests/ProjectsStoreTests.swift`

- [x] **Step 1：写失败测试（按 cwd 分组 + 显式 sourceKinds + 徽标）**

`ios/CodexRemoteTests/ProjectsStoreTests.swift`：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ProjectsStoreTests: XCTestCase {
    func testGroupsThreadsByCwd() {
        let store = ProjectsStore()
        store.ingest([
            ThreadSummary(id: "a", sessionId: "s", preview: "p1", modelProvider: "openai",
                          createdAt: 1, updatedAt: 2, cwd: "/repo/x", cliVersion: "0", name: "A"),
            ThreadSummary(id: "b", sessionId: "s", preview: "p2", modelProvider: "openai",
                          createdAt: 1, updatedAt: 3, cwd: "/repo/x", cliVersion: "0", name: nil),
            ThreadSummary(id: "c", sessionId: "s", preview: "p3", modelProvider: "openai",
                          createdAt: 1, updatedAt: 4, cwd: "/repo/y", cliVersion: "0", name: "C"),
        ])
        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.projects.first(where: { $0.cwd == "/repo/x" })?.threads.count, 2)
    }

    func testListParamsRequestsDesktopSource() {
        // session-management「桌面来源会话可见」：显式覆盖 sourceKinds
        let params = ProjectsStore.listParamsForDesktopVisibility()
        XCTAssertTrue(params.sourceKinds?.contains("appServer") ?? false)
    }

    func testPendingApprovalBadge() {
        let store = ProjectsStore()
        store.ingest([ThreadSummary(id: "a", sessionId: "s", preview: "p", modelProvider: "o",
                       createdAt: 1, updatedAt: 2, cwd: "/r", cliVersion: "0", name: "A")])
        store.setPendingApproval(threadId: "a", pending: true)
        XCTAssertTrue(store.hasPendingApproval("a"))
        store.setPendingApproval(threadId: "a", pending: false)
        XCTAssertFalse(store.hasPendingApproval("a"))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ProjectsStoreTests`
Expected：编译失败（`ProjectsStore` 未定义）。

- [x] **Step 3：实现 ProjectsStore**

`ios/CodexRemote/Stores/ProjectsStore.swift`：

```swift
import Foundation
import Observation

struct Project: Identifiable {
    var id: String { cwd }
    let cwd: String
    var threads: [ThreadSummary]
    var displayName: String { (cwd as NSString).lastPathComponent }
}

@Observable
@MainActor
final class ProjectsStore {
    private(set) var projects: [Project] = []
    private var pendingApproval: Set<String> = []

    /// session-management「桌面来源会话可见」：默认 sourceKinds 可能不含桌面 app（appServer）来源，
    /// 显式覆盖以确保桌面会话出现（设计 §13 Open Question，build 实测确认；不含也无害）。
    static func listParamsForDesktopVisibility() -> ThreadListParams {
        ThreadListParams(limit: 100,
                         sourceKinds: ["cli", "vscode", "exec", "appServer"], cwd: nil)
    }

    func loadFromServer(rpc: JSONRPCClient) async {
        let params = Self.listParamsForDesktopVisibility()
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let result = try? await rpc.send(method: RPCMethod.threadList, params: any),
              let resData = try? JSONEncoder().encode(result),
              let resp = try? JSONDecoder().decode(ThreadListResponse.self, from: resData)
        else { return }
        ingest(resp.data)
    }

    func ingest(_ threads: [ThreadSummary]) {
        let grouped = Dictionary(grouping: threads, by: \.cwd)
        projects = grouped.map { cwd, ts in
            Project(cwd: cwd, threads: ts.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { $0.cwd < $1.cwd }
    }

    func setPendingApproval(threadId: String, pending: Bool) {
        if pending { pendingApproval.insert(threadId) } else { pendingApproval.remove(threadId) }
    }
    func hasPendingApproval(_ threadId: String) -> Bool { pendingApproval.contains(threadId) }
}
```

- [x] **Step 4：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ProjectsStoreTests`
Expected：全部 PASS。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/Stores/ProjectsStore.swift ios/CodexRemoteTests/ProjectsStoreTests.swift
git commit -m "feat(stores): ProjectsStore groups threads by cwd, desktop sourceKinds, pending-approval badge"
```

---

## Task 13：SwiftUI 左栏（项目→对话树）+ 三栏骨架

**对应 spec：** `session-management/spec.md`「左栏按项目分组展示对话」「显示等待批准徽标」+ 设计 §3/D7（横屏三列 `NavigationSplitView`，竖屏抽屉化）。依赖 Task 12。

**Files:**
- Create: `ios/CodexRemote/Views/RootSplitView.swift`
- Create: `ios/CodexRemote/Views/SidebarView.swift`
- Modify: `ios/CodexRemote/App/CodexRemoteApp.swift`（从 SpikeView 切到正式根）

- [x] **Step 1：实现三栏骨架**

`ios/CodexRemote/Views/RootSplitView.swift`：

```swift
import SwiftUI

struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @State private var selectedThreadId: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedThreadId: $selectedThreadId)
        } content: {
            if let id = selectedThreadId {
                ConversationView(threadId: id)
            } else {
                ContentUnavailableView("选择一个对话", systemImage: "bubble.left.and.bubble.right")
            }
        } detail: {
            InspectorPlaceholderView()    // v1 简态，右栏富态留 v2+
        }
    }
}

struct InspectorPlaceholderView: View {
    var body: some View { Text("输出 / 来源").foregroundStyle(.secondary) }
}
```

- [x] **Step 2：实现左栏（项目→对话树 + 待批准徽标）**

`ios/CodexRemote/Views/SidebarView.swift`：

```swift
import SwiftUI

struct SidebarView: View {
    @Environment(ProjectsStore.self) private var projects
    @Environment(ConnectionStore.self) private var connection
    @Binding var selectedThreadId: String?

    var body: some View {
        List(selection: $selectedThreadId) {
            ForEach(projects.projects) { project in
                Section(project.displayName) {
                    ForEach(project.threads) { thread in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(thread.name ?? thread.preview).lineLimit(1)
                                Text(relativeTime(thread.updatedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if projects.hasPendingApproval(thread.id) {
                                Label("等待批准", systemImage: "clock.badge.exclamationmark")
                                    .labelStyle(.iconOnly).foregroundStyle(.orange)
                            }
                        }
                        .tag(thread.id)
                    }
                }
            }
        }
        .navigationTitle("项目")
        .task { if let rpc = connection.rpc { await projects.loadFromServer(rpc: rpc) } }
    }

    private func relativeTime(_ ts: Double) -> String {
        RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}
```

- [x] **Step 3：切换 App 根视图并装配 Stores**

修改 `ios/CodexRemote/App/CodexRemoteApp.swift`：根据连接状态在 `ConnectionConfigView` 与 `RootSplitView` 间切换，并把 Stores 注入环境：

```swift
import SwiftUI

@main
struct CodexRemoteApp: App {
    @State private var connection = ConnectionStore(transportFactory: liveTransportFactory)
    @State private var projects = ProjectsStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.phase == .ready || connection.phase == .reconnecting {
                    RootSplitView()
                } else {
                    ConnectionConfigView()
                }
            }
            .environment(connection)
            .environment(projects)
            .overlay(alignment: .top) { reconnectBanner }
        }
    }

    @ViewBuilder private var reconnectBanner: some View {
        if connection.phase == .reconnecting {
            Text("重连中…").padding(6).background(.yellow.opacity(0.3)).clipShape(Capsule())
        }
    }
}
```

- [x] **Step 4：编译验证 + 模拟器目视**

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功。在模拟器运行应看到连接配置界面（未连接态）；连接后切到三栏空壳。

> UI 真功能（拉到真实会话）在 Task 20 真机 E2E 验证；此处仅验证骨架与目视无崩溃。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/Views/RootSplitView.swift ios/CodexRemote/Views/SidebarView.swift ios/CodexRemote/App/CodexRemoteApp.swift
git commit -m "feat(ui): three-pane NavigationSplitView + sidebar project/thread tree with approval badge"
```

---

## Task 14：状态层 ConversationStore（resume/start/turn + 流式归约接线）

**对应 spec：** `session-management/spec.md`「恢复桌面 app 创建的会话」「新建对话」+ `conversation-streaming/spec.md`「发送 prompt 并看到流式正文」。依赖 Task 8/9。

**Files:**
- Create: `ios/CodexRemote/Stores/ConversationStore.swift`
- Test: `ios/CodexRemoteTests/ConversationStoreTests.swift`

- [x] **Step 1：写失败测试（resume 加载 + 流式 delta 归约进 state）**

`ios/CodexRemoteTests/ConversationStoreTests.swift`：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testStreamingDeltaUpdatesState() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.startObserving()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"turnId":"T1"}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"itemId":"I1","itemType":"agentMessage"}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"itemId":"I1","delta":"Hi"}}"#)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .agentMessage(_, let t)? = store.state.items.first else { return XCTFail() }
        XCTAssertEqual(t, "Hi")
    }

    func testSendPromptIssuesTurnStart() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.send(input: [.text("hello")], model: "gpt-5", effort: .high)
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = await mock.sent.last!
        XCTAssertTrue(sent.contains("turn/start"))
        XCTAssertTrue(sent.contains(#""effort":"high""#))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ConversationStoreTests`
Expected：编译失败（`ConversationStore` 未定义）。

- [x] **Step 3：实现 ConversationStore**

`ios/CodexRemote/Stores/ConversationStore.swift`：

```swift
import Foundation
import Observation

@Observable
@MainActor
final class ConversationStore {
    private(set) var state: ConversationState
    var queuedInputs: [[UserInput]] = []        // Task 17 排队用
    private let rpc: JSONRPCClient
    private let reducer = ThreadReducer()

    init(rpc: JSONRPCClient, threadId: String) {
        self.rpc = rpc
        self.state = ConversationState(threadId: threadId)
    }

    func startObserving() {
        Task { [weak self] in
            guard let self else { return }
            for await n in await rpc.notifications() {
                await MainActor.run {
                    // 仅消费属于本线程的事件（按 params.threadId 过滤，缺省全收）
                    self.reducer.apply(n, to: &self.state)
                    self.drainQueueIfTurnEnded(n)
                }
            }
        }
    }

    func resume() async {
        let params = ThreadResumeParams(threadId: state.threadId)
        _ = try? await call(RPCMethod.threadResume, params)
        // resume 响应含历史，可在此把历史 item 灌入 state（MVP：依赖后续 read/通知补全）
    }

    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async {
        let params = TurnStartParams(threadId: state.threadId, input: input,
                                     model: model, effort: effort, cwd: nil)
        _ = try? await call(RPCMethod.turnStart, params)
    }

    private func drainQueueIfTurnEnded(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.turnCompleted,
              !queuedInputs.isEmpty else { return }
        let next = queuedInputs.removeFirst()
        Task { await send(input: next, model: nil, effort: nil) }
    }

    private func call<T: Encodable>(_ method: String, _ params: T) async throws -> AnyCodable {
        let data = try JSONEncoder().encode(params)
        let any = try JSONDecoder().decode(AnyCodable.self, from: data)
        return try await rpc.send(method: method, params: any)
    }
}
```

- [x] **Step 4：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ConversationStoreTests`
Expected：全部 PASS。

- [x] **Step 5：Commit**

```bash
git add ios/CodexRemote/Stores/ConversationStore.swift ios/CodexRemoteTests/ConversationStoreTests.swift
git commit -m "feat(stores): ConversationStore wires turn/start, resume, streaming reduction, queue drain"
```

---

## Task 15：SwiftUI 中栏对话流（正文/命令输出/文件 diff 卡）

**对应 spec：** `conversation-streaming/spec.md`「发送 prompt 并看到流式正文」「渲染命令执行输出」「渲染文件改动 diff」。依赖 Task 14。

**Files:**
- Create: `ios/CodexRemote/Views/ConversationView.swift`
- Create: `ios/CodexRemote/Views/ItemCards.swift`

- [x] **Step 1：实现对话流视图（按 item 类型分发卡片）**

`ios/CodexRemote/Views/ConversationView.swift`：

```swift
import SwiftUI

struct ConversationView: View {
    @Environment(ConnectionStore.self) private var connection
    let threadId: String
    @State private var store: ConversationStore?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store?.state.items ?? []) { item in
                        ItemCard(item: item).id(item.id)
                    }
                }.padding()
            }
            .onChange(of: store?.state.items.count) { _, _ in
                if let last = store?.state.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let store { ComposerView(store: store) }
        }
        .navigationTitle("对话")
        .task(id: threadId) {
            guard let rpc = connection.rpc else { return }
            let s = ConversationStore(rpc: rpc, threadId: threadId)
            s.startObserving()
            await s.resume()                 // session-management: 恢复已有会话历史
            store = s
        }
    }
}
```

- [x] **Step 2：实现各类 item 卡片（正文 Markdown / 命令输出 / 文件 diff）**

`ios/CodexRemote/Views/ItemCards.swift`：

```swift
import SwiftUI

struct ItemCard: View {
    let item: ConversationItem
    var body: some View {
        switch item {
        case .userMessage(_, let text):
            HStack { Spacer(); Text(text).padding(10)
                .background(.blue.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 12)) }
        case .agentMessage(_, let text):
            Text(.init(text))            // Markdown 渲染（代码块/格式）
                .frame(maxWidth: .infinity, alignment: .leading)
        case .commandExecution(_, let command, let output, let finished):
            VStack(alignment: .leading, spacing: 4) {
                Label(command, systemImage: finished ? "terminal" : "terminal.fill")
                    .font(.callout.monospaced())
                if !output.isEmpty {
                    Text(output).font(.footnote.monospaced())
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        case .fileChange(_, let file, let added, let removed, let diff):
            DisclosureGroup {
                DiffView(diff: diff)
            } label: {
                HStack {
                    Image(systemName: "doc.text"); Text(file).font(.callout.monospaced())
                    Spacer()
                    Text("+\(added)").foregroundStyle(.green)
                    Text("-\(removed)").foregroundStyle(.red)
                }
            }
        }
    }
}

struct DiffView: View {
    let diff: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line)).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lineColor(String(line)))
            }
        }
    }
    private func lineColor(_ l: String) -> Color {
        if l.hasPrefix("+") { return .green.opacity(0.15) }
        if l.hasPrefix("-") { return .red.opacity(0.15) }
        return .clear
    }
}
```

> `ComposerView` 在 Task 16 实现；此处先引用其签名 `ComposerView(store:)`。若 Task 16 尚未做，临时用 `Text("composer")` 占位编译，待 Task 16 替换。

- [x] **Step 3：编译验证**

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功（功能性渲染在 Task 20 真机 E2E 验证）。

- [x] **Step 4：Commit**

```bash
git add ios/CodexRemote/Views/ConversationView.swift ios/CodexRemote/Views/ItemCards.swift
git commit -m "feat(ui): conversation stream with agent markdown, command output, file diff cards"
```

---

## Task 16：composer（文本/图片/模型推理选择 + turn/start 映射）

**对应 spec：** `conversation-streaming/spec.md`「图片附件」「调整模型与推理强度」+「发送 prompt」。依赖 Task 14。

**Files:**
- Create: `ios/CodexRemote/Views/ComposerView.swift`

- [x] **Step 1：实现 composer（文本 + 图片选择 + 模型/推理选择器 + 发送）**

`ios/CodexRemote/Views/ComposerView.swift` —— 图片经 `PhotosPicker` 选取，转 base64 data URL 作 `UserInput.image`（或本地路径不可用，故用内联 url）；模型/推理映射 `turn/start` 的 `model`/`effort`：

```swift
import SwiftUI
import PhotosUI

struct ComposerView: View {
    let store: ConversationStore
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageDataURL: String?
    @State private var model = "gpt-5"
    @State private var effort: ReasoningEffort = .medium

    var body: some View {
        VStack(spacing: 6) {
            if imageDataURL != nil {
                HStack { Image(systemName: "photo").foregroundStyle(.blue)
                    Text("已附加图片"); Spacer()
                    Button("移除") { imageDataURL = nil } }
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus.circle")
                }
                Menu {
                    Picker("模型", selection: $model) {
                        Text("gpt-5").tag("gpt-5"); Text("gpt-5-codex").tag("gpt-5-codex")
                    }
                    Picker("推理", selection: $effort) {
                        ForEach([ReasoningEffort.low, .medium, .high, .xhigh], id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                TextField("发消息…", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(text.isEmpty && imageDataURL == nil)
            }
        }
        .padding(8)
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    imageDataURL = "data:image/jpeg;base64," + data.base64EncodedString()
                }
            }
        }
    }

    private func send() async {
        var input: [UserInput] = []
        if !text.isEmpty { input.append(.text(text)) }
        if let url = imageDataURL { input.append(.image(url: url, detail: .high)) }
        guard !input.isEmpty else { return }
        await store.send(input: input, model: model, effort: effort)   // 映射 turn/start
        text = ""; imageDataURL = nil; photoItem = nil
    }
}
```

- [x] **Step 2：把 Task 15 的占位换成真实 ComposerView**

确认 `ConversationView` 的 `safeAreaInset` 使用 `ComposerView(store: store)`（若 Task 15 用了占位文本，替换之）。

- [x] **Step 3：编译验证**

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功。

- [x] **Step 4：Commit**

```bash
git add ios/CodexRemote/Views/ComposerView.swift ios/CodexRemote/Views/ConversationView.swift
git commit -m "feat(ui): composer with text, image attachment, model/effort selectors mapped to turn/start"
```

---

## Task 17：中途控制（steer / 排队 / interrupt）

**对应 spec：** `conversation-streaming/spec.md`「转向活动 turn」「排队后续输入」「转向不可 steer 的 turn」「中断进行中的 turn」。依赖 Task 14/16。

**Files:**
- Modify: `ios/CodexRemote/Stores/ConversationStore.swift`（加 steer/interrupt/enqueue）
- Modify: `ios/CodexRemote/Views/ComposerView.swift`（turn 运行时给出 转向/排队/中断 选项）
- Test: `ios/CodexRemoteTests/MidTurnControlTests.swift`

- [x] **Step 1：写失败测试（steer 带 expectedTurnId / 不可 steer 拦截 / 排队缓冲 / interrupt）**

`ios/CodexRemoteTests/MidTurnControlTests.swift`：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class MidTurnControlTests: XCTestCase {
    private func runningStore() async -> (ConversationStore, MockTransport) {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.startObserving()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"turnId":"T1"}}"#)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return (store, mock)
    }

    func testSteerSendsExpectedTurnId() async throws {
        let (store, mock) = await runningStore()
        await store.steer(input: [.text("change course")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = await mock.sent.last!
        XCTAssertTrue(sent.contains("turn/steer"))
        XCTAssertTrue(sent.contains(#""expectedTurnId":"T1""#))
    }

    func testSteerBlockedForReviewTurn() async throws {
        let (store, mock) = await runningStore()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"turnId":"T2","kind":"review"}}"#)
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = await mock.sent.count
        let ok = await store.steer(input: [.text("x")])
        XCTAssertFalse(ok)                       // review 不可 steer
        XCTAssertEqual(await mock.sent.count, before)
    }

    func testEnqueueBuffersWhenRunning() async throws {
        let (store, _) = await runningStore()
        store.enqueue(input: [.text("later")])
        XCTAssertEqual(store.queuedInputs.count, 1)
    }

    func testInterruptSends() async throws {
        let (store, mock) = await runningStore()
        await store.interrupt()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(await mock.sent.last!.contains("turn/interrupt"))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/MidTurnControlTests`
Expected：编译失败（`steer`/`interrupt`/`enqueue` 未定义）。

- [x] **Step 3：在 ConversationStore 实现 steer/enqueue/interrupt**

向 `ios/CodexRemote/Stores/ConversationStore.swift` 追加：

```swift
extension ConversationStore {
    /// 返回是否成功发出 steer。review/compact 类型不可 steer（返回 false）。
    @discardableResult
    func steer(input: [UserInput]) async -> Bool {
        guard let turnId = state.activeTurnId, state.activeTurnKind == nil else { return false }
        let params = TurnSteerParams(threadId: state.threadId, input: input, expectedTurnId: turnId)
        _ = try? await call(RPCMethod.turnSteer, params)
        return true
    }

    func enqueue(input: [UserInput]) {
        queuedInputs.append(input)        // turn/completed 后由 drainQueueIfTurnEnded 发送
    }

    func interrupt() async {
        let params = TurnInterruptParams(threadId: state.threadId)
        _ = try? await call(RPCMethod.turnInterrupt, params)
    }
}
```

> `call`/`drainQueueIfTurnEnded`/`queuedInputs` 已在 Task 14 定义；此处复用。`call` 需从 private 提升为 internal（同模块可见）以便 extension 调用——把 Task 14 中 `private func call` 改为 `func call`。

- [x] **Step 4：composer 在 turn 运行时提供 转向/排队/中断 UI**

向 `ComposerView` 加入：当 `store.state.isTurnRunning` 时，发送按钮旁出现「中断」按钮，且发送动作改为弹出菜单（转向 / 排队）；若 `store.state.activeTurnKind != nil`（review/compact）则禁用「转向」并提示「本回合不支持转向」：

```swift
// 在 ComposerView body 的 HStack 中，发送按钮替换为：
if store.state.isTurnRunning {
    Button(role: .destructive) { Task { await store.interrupt() } } label: {
        Image(systemName: "stop.circle.fill")
    }
    Menu {
        Button("转向当前回合") { Task { await trySteer() } }
            .disabled(store.state.activeTurnKind != nil)
        Button("排队，回合结束后发送") { enqueueCurrent() }
        if store.state.activeTurnKind != nil {
            Text("本回合（\(store.state.activeTurnKind!.rawValue)）不支持转向").foregroundStyle(.secondary)
        }
    } label: { Image(systemName: "arrow.up.circle.fill") }
        .disabled(text.isEmpty && imageDataURL == nil)
} else {
    Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill") }
        .disabled(text.isEmpty && imageDataURL == nil)
}
```

并加两个辅助方法（构造 input 同 `send()`）：

```swift
private func currentInput() -> [UserInput] {
    var input: [UserInput] = []
    if !text.isEmpty { input.append(.text(text)) }
    if let url = imageDataURL { input.append(.image(url: url, detail: .high)) }
    return input
}
private func trySteer() async {
    let input = currentInput(); guard !input.isEmpty else { return }
    let ok = await store.steer(input: input)
    if ok { text = ""; imageDataURL = nil; photoItem = nil }
}
private func enqueueCurrent() {
    let input = currentInput(); guard !input.isEmpty else { return }
    store.enqueue(input: input); text = ""; imageDataURL = nil; photoItem = nil
}
```

- [x] **Step 5：运行测试确认通过 + 编译**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/MidTurnControlTests`
Expected：全部 PASS。再 `xcodebuild build …` 确认 UI 编译通过。

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Stores/ConversationStore.swift ios/CodexRemote/Views/ComposerView.swift ios/CodexRemoteTests/MidTurnControlTests.swift
git commit -m "feat(conversation): steer (with expectedTurnId), queue, interrupt + non-steerable guard"
```

---

## Task 18：状态层 + UI ApprovalStore + 多选项审批卡（含 legacy 兼容）

**对应 spec：** `approval-flow/spec.md`「命令执行审批」「文件改动审批」「兼容 legacy 审批」「批准」「批准并本会话放行前缀」「拒绝」。依赖 Task 8/5/13。

**Files:**
- Create: `ios/CodexRemote/Stores/ApprovalStore.swift`
- Create: `ios/CodexRemote/Views/ApprovalCardView.swift`
- Test: `ios/CodexRemoteTests/ApprovalStoreTests.swift`

- [x] **Step 1：写失败测试（识别 v2/legacy 请求 + 三种 decision 回传正确形状）**

`ios/CodexRemoteTests/ApprovalStoreTests.swift`：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ApprovalStoreTests: XCTestCase {
    func testV2CommandRequestEnqueuesCard() async throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId":"t1","turnId":"T1","itemId":"I1","command":"rm -rf x"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.threadId, "t1")
    }

    func testV2ApproveWithPrefixEncodesAmendment() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2,
                                      decision: .approveForSessionPrefix(["git","status"]))
        let s = String(data: try JSONEncoder().encode(resp), encoding: .utf8)!
        XCTAssertTrue(s.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(s.contains("execpolicy_amendment"))
    }

    func testV2DeclineEncodes() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .deny)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("decline"))
    }

    func testLegacyExecApprovalUsesReviewDecision() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.execApprovalLegacy, decision: .approve)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("approved"))
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ApprovalStoreTests`
Expected：编译失败（`ApprovalStore` 未定义）。

- [x] **Step 3：实现 ApprovalStore（统一多选项决定 → 按方法映射到 v2/legacy 形状）**

`ios/CodexRemote/Stores/ApprovalStore.swift`：

```swift
import Foundation
import Observation

/// UI 层统一的三选项决定，落地时按方法映射到 v2/legacy 的不同 decision 形状。
enum ApprovalChoice: Equatable {
    case approve                            // 是
    case approveForSessionPrefix([String])  // 是，且此前缀本会话不再询问
    case deny                               // 否
}

struct ApprovalCard: Identifiable {
    let id: RequestId
    let method: String
    let threadId: String
    let title: String       // 命令文本或文件名
    let detail: String      // 命令明细或 diff 摘要
    let proposedPrefix: [String]?   // v2 命令审批可能携带 proposedExecpolicyAmendment
    let isFileChange: Bool
}

@Observable
@MainActor
final class ApprovalStore {
    private(set) var cards: [ApprovalCard] = []
    /// 回传响应的回调，由接线方注入（实际调用 rpc 的 server-request handler 完成）。
    var resolver: (@MainActor (RequestId, AnyCodable) async -> Void)?
    /// 通知 ProjectsStore 更新徽标。
    var onPendingChange: (@MainActor (_ threadId: String, _ pending: Bool) -> Void)?

    func handle(request req: JSONRPCRequest) {
        let p = (req.params?.value as? [String: Any]) ?? [:]
        let threadId = p["threadId"] as? String ?? ""
        let isFile = req.method == ServerRequestMethod.fileApprovalV2
                  || req.method == ServerRequestMethod.applyPatchApprovalLegacy
        let card = ApprovalCard(
            id: req.id, method: req.method, threadId: threadId,
            title: isFile ? (p["file"] as? String ?? "文件改动") : (p["command"] as? String ?? "命令"),
            detail: isFile ? (p["diff"] as? String ?? "") : (p["cwd"] as? String ?? ""),
            proposedPrefix: p["proposedExecpolicyAmendment"] as? [String],
            isFileChange: isFile)
        cards.append(card)
        onPendingChange?(threadId, true)
    }

    func resolve(card: ApprovalCard, choice: ApprovalChoice) async {
        let body = responseBody(for: card.method, decision: choice)
        let any = (try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(body)))
            ?? AnyCodable([String: Any]())
        await resolver?(card.id, any)
        remove(card.id, threadId: card.threadId)
    }

    func remove(_ id: RequestId, threadId: String) {
        cards.removeAll { $0.id == id }
        if !cards.contains(where: { $0.threadId == threadId }) { onPendingChange?(threadId, false) }
    }

    /// 按请求方法把统一选项映射到正确的 decision 形状。返回可编码的 body。
    func responseBody(for method: String, decision: ApprovalChoice) -> some Encodable {
        let isLegacy = method == ServerRequestMethod.execApprovalLegacy
                    || method == ServerRequestMethod.applyPatchApprovalLegacy
        let isFile = method == ServerRequestMethod.fileApprovalV2
        if isLegacy {
            let d: ReviewDecision
            switch decision {
            case .approve: d = .approved
            case .approveForSessionPrefix(let p): d = .approvedExecpolicyAmendment(proposed: p)
            case .deny: d = .denied
            }
            return AnyEncodable(ExecCommandApprovalResponse(decision: d))
        } else if isFile {
            // 文件审批无前缀放行语义，前缀选项降级为 acceptForSession
            let d: FileChangeApprovalDecision
            switch decision {
            case .approve: d = .accept
            case .approveForSessionPrefix: d = .acceptForSession
            case .deny: d = .decline
            }
            return AnyEncodable(FileChangeApprovalResponse(decision: d))
        } else {
            let d: CommandExecutionApprovalDecision
            switch decision {
            case .approve: d = .accept
            case .approveForSessionPrefix(let p): d = .acceptWithExecpolicyAmendment(execpolicyAmendment: p)
            case .deny: d = .decline
            }
            return AnyEncodable(CommandExecutionApprovalResponse(decision: d))
        }
    }
}

/// 类型擦除 Encodable，便于 responseBody 返回统一类型。
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { _encode = v.encode }
    func encode(to e: Encoder) throws { try _encode(e) }
}
```

> 测试中 `responseBody(for:decision:)` 返回 `some Encodable`，但测试用 `JSONEncoder().encode(resp)` 直接编码 `AnyEncodable`，可行。若编译器对 `some Encodable` 在测试调用处推断不便，把返回类型显式改为 `AnyEncodable`。

- [x] **Step 4：实现审批卡 UI（多选项）**

`ios/CodexRemote/Views/ApprovalCardView.swift`：

```swift
import SwiftUI

struct ApprovalCardView: View {
    @Environment(ApprovalStore.self) private var approvals
    let card: ApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.isFileChange ? "文件改动审批" : "命令执行审批",
                  systemImage: card.isFileChange ? "doc.badge.gearshape" : "terminal")
                .font(.headline)
            Text(card.title).font(.callout.monospaced())
            if !card.detail.isEmpty {
                Text(card.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            HStack {
                Button("是") { resolve(.approve) }.buttonStyle(.borderedProminent)
                if !card.isFileChange, let prefix = card.proposedPrefix ?? defaultPrefix(card.title) {
                    Button("是，且本会话放行此前缀") { resolve(.approveForSessionPrefix(prefix)) }
                }
                Spacer()
                Button("否", role: .destructive) { resolve(.deny) }
            }
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func resolve(_ choice: ApprovalChoice) {
        Task { await approvals.resolve(card: card, choice: choice) }
    }
    /// 无 server 建议前缀时，用命令首 token 作前缀放行。
    private func defaultPrefix(_ command: String) -> [String]? {
        let toks = command.split(separator: " ").map(String.init)
        return toks.isEmpty ? nil : [toks[0]]
    }
}
```

并在 `ConversationView` 的 item 列表上方/下方插入属于当前线程的审批卡（从 `ApprovalStore.cards` 过滤 `threadId == threadId`）。

- [x] **Step 5：把 ApprovalStore 接到 JSONRPCClient 的 server-request handler**

在 App 装配处（`CodexRemoteApp` 或一个协调器）注册：`connection.rpc?.setServerRequestHandler` 内部把请求交给 `ApprovalStore.handle(request:)`，并通过 `withCheckedContinuation` 等待用户在 UI 选择后由 `resolver` 回填响应。把 `ApprovalStore.resolver` 设为「完成对应 continuation」。注入 `onPendingChange` 调 `ProjectsStore.setPendingApproval`。

```swift
// 协调示意（放在 App 或 AppCoordinator）：
approvals.onPendingChange = { tid, pending in projects.setPendingApproval(threadId: tid, pending: pending) }
await connection.rpc?.setServerRequestHandler { req in
    await withCheckedContinuation { (cont: CheckedContinuation<AnyCodable, Never>) in
        Task { @MainActor in
            approvals.pendingContinuations[req.id] = cont       // 待用户决定
            approvals.handle(request: req)
        }
    }
}
approvals.resolver = { id, body in
    approvals.pendingContinuations.removeValue(forKey: id)?.resume(returning: body)
}
```

> 为此在 `ApprovalStore` 增 `var pendingContinuations: [RequestId: CheckedContinuation<AnyCodable, Never>] = [:]`。

- [x] **Step 6：运行测试确认通过 + 编译**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ApprovalStoreTests`
Expected：全部 PASS。再 `xcodebuild build …`。

- [x] **Step 7：Commit**

```bash
git add ios/CodexRemote/Stores/ApprovalStore.swift ios/CodexRemote/Views/ApprovalCardView.swift ios/CodexRemote/App ios/CodexRemoteTests/ApprovalStoreTests.swift
git commit -m "feat(approval): multi-option approval store + card, v2/legacy decision mapping, badge wiring"
```

---

## Task 19：审批边界（serverRequest/resolved + 超时/断线不自动批准）

**对应 spec：** `approval-flow/spec.md`「审批被他端解决」「超时或断线未决不自动批准」。依赖 Task 18/10。

**Files:**
- Modify: `ios/CodexRemote/Stores/ApprovalStore.swift`
- Test: `ios/CodexRemoteTests/ApprovalBoundaryTests.swift`

- [x] **Step 1：写失败测试（resolved 移除卡片 / 断线不自动批准、标记待恢复）**

`ios/CodexRemoteTests/ApprovalBoundaryTests.swift`：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ApprovalBoundaryTests: XCTestCase {
    private func cardStore() -> ApprovalStore {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId":"t1","command":"ls"]))
        store.handle(request: req)
        return store
    }

    func testResolvedByOtherRemovesCard() {
        let store = cardStore()
        XCTAssertEqual(store.cards.count, 1)
        store.handleServerRequestResolved(requestId: .string("r1"), threadId: "t1")
        XCTAssertTrue(store.cards.isEmpty)        // 他端处理后移除
    }

    func testDisconnectMarksPendingNotAutoApproved() async {
        let store = cardStore()
        var autoApproved = false
        store.resolver = { _, _ in autoApproved = true }    // 若被调用即视为自动回传
        store.handleConnectionLost()
        XCTAssertFalse(autoApproved)                 // 绝不自动批准
        XCTAssertTrue(store.cards.first?.awaitingRecovery ?? false)  // 标记待恢复
    }
}
```

- [x] **Step 2：运行测试确认失败**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ApprovalBoundaryTests`
Expected：编译失败（方法/字段未定义）。

- [x] **Step 3：在 ApprovalStore 实现边界处理**

向 `ApprovalStore` 增加（并给 `ApprovalCard` 加 `var awaitingRecovery = false`，改为可变 struct 字段）：

```swift
extension ApprovalStore {
    /// serverRequest/resolved：某审批被他端（如桌面）先处理。
    func handleServerRequestResolved(requestId: RequestId, threadId: String) {
        // 移除卡片但**不回传**响应（服务端已被他端解决）。
        if let cont = pendingContinuations.removeValue(forKey: requestId) {
            cont.resume(returning: AnyCodable(NSNull()))   // 释放挂起的 handler，避免泄漏
        }
        remove(requestId, threadId: threadId)
    }

    /// 连接中断：未决审批标记待恢复，绝不自动批准。
    func handleConnectionLost() {
        for i in cards.indices { cards[i].awaitingRecovery = true }
        // 不调用 resolver / 不 resume continuation：等重连后服务端重发（重发会再次走 handle）
    }
}
```

> `serverRequest/resolved` 通知的 `requestId` 字段名以真实 `ServerNotification.json` 为准；Task 20 录制真实帧后核对（设计 §13）。

- [x] **Step 4：把通知接线到 ApprovalStore**

在 App 协调处，订阅 `rpc.notifications()`：遇到 `serverRequest/resolved` → 解析 requestId/threadId → `approvals.handleServerRequestResolved`；在 `ConnectionStore.phase` 变为 `.reconnecting` 时调 `approvals.handleConnectionLost()`。

- [x] **Step 5：运行测试确认通过**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:CodexRemoteTests/ApprovalBoundaryTests`
Expected：全部 PASS。

- [x] **Step 6：Commit**

```bash
git add ios/CodexRemote/Stores/ApprovalStore.swift ios/CodexRemote/App ios/CodexRemoteTests/ApprovalBoundaryTests.swift
git commit -m "feat(approval): handle serverRequest/resolved + connection-loss without auto-approval"
```

---

## Task 20：E2E 联调与验收（4 个手动 E2E 场景）

**对应 spec：** tasks.md §7 全部 + 跨 spec 验收。这是真机 + 真实 Mac app-server 的手动 E2E（设计 §10：SSH/WS 无法纯单元测试）。同时**录制真实帧**回填到前序任务的 fixture 与字段名校正点。

**Files:**
- Create: `docs/superpowers/plans/e2e-checklist-ipad-codex-remote-client.md`（验收清单 + 录制帧归档）
- Modify（按需）：`ios/CodexRemote/Domain/ThreadReducer.swift`、`Protocol/*`、`ApprovalStore.swift`（按真实帧校正字段名）

- [ ] **Step 1：准备真机 E2E 环境**

在 Mac 跑 `./scripts/start-codex-appserver.sh`（Task 2，确保受管 daemon 已启用远程控制）；iPad 与 Mac 同 LAN；Xcode 选真实 iPad 运行 app；用 `ConnectionConfigView` 填真实 SSH 凭证连接。

- [ ] **Step 2：E2E 场景 1 — 连 + 发 + 流式（tasks 7.1）**

操作：连接 → 新建对话 → composer 发一条「列出当前目录文件」→ 观察。
Expected（对应 `conversation-streaming` 验收）：进入 ready；`turn/start` 发出；`item/agentMessage/delta` 增量渲染正文；若触发命令则 `outputDelta` 渲染命令输出；`turn/completed` 后回合结束。
录制：用临时日志把收到的原始 JSON 帧打印/保存，归档到 e2e 清单文档。

- [ ] **Step 3：E2E 场景 2 — 恢复桌面 app 会话（tasks 7.2）**

前置：先在 Mac 的 Codex 桌面 app 里创建一个会话。
操作：iPad 连接 → 左栏应出现该会话（按 cwd 分组）→ 选中 → `thread/resume` 加载历史 → 继续发一条。
Expected（对应 `session-management` 验收）：桌面来源会话可见（若不可见，确认 `listParamsForDesktopVisibility` 的 `sourceKinds` 是否需含其它值——这是设计 §13 待确认项，按实测校正 `ProjectsStore`）；resume 后历史渲染、可继续对话。

- [ ] **Step 4：E2E 场景 3 — 审批闭环：批准 + 拒绝（tasks 7.3）**

操作：发一条会触发命令/文件修改审批的指令 → iPad 出现多选项审批卡。
路径 A 批准：点「是」→ 渲染执行结果。
路径 B 拒绝：再触发一次 → 点「否」→ Codex 收到拒绝。
路径 C（附加）：点「是，且本会话放行此前缀」→ 同前缀命令后续不再弹卡。
Expected（对应 `approval-flow` 验收）：三种 decision 以正确形状回传（用录制帧核对 v2 `accept`/`decline`/`acceptWithExecpolicyAmendment` 字段）；徽标在未决时出现、解决后消失。

- [ ] **Step 5：E2E 场景 4 — 断线重连 + 鉴权失败报错（tasks 7.4）**

操作 A：连接后断开 iPad WiFi 几秒再恢复 → 观察「重连中」横幅 → 自动重建 SSH 连接 + 重新 exec `codex app-server proxy` + `initialize` + 对当前线程 `thread/resume`。
操作 B：故意填错 SSH 密码连接 → 应显示明确「SSH 鉴权失败」而非泛化错误。
操作 C：SSH 通但受管 daemon 未启用远程控制（control socket 不存在）→ 应显示「app-server 不可达」。
Expected（对应 `remote-connection` 验收）：三种情形均符合 spec。

- [x] **Step 6：回填 fixture 与字段校正**

用 E2E 录制的真实帧：①核对并校正 `ThreadReducer` 中的字段名（`itemId`/`delta`/`itemType`/`command`/`kind`/diff 字段）；②校正 `ApprovalStore.handle` 取的参数键；③校正 `serverRequest/resolved` 的 requestId 字段名；④把若干真实帧序列存为新的 fixture，补一条 `ThreadReducerTests` 用真实帧回归。每次校正后重跑相关单测确认仍 PASS。

- [x] **Step 7：移除 spike 临时代码**

确认 `SpikeView`/`SpikeRunner` 已不被引用（App 根已切到正式视图），删除 `ios/CodexRemote/Spike/` 目录。

Run：`xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：编译成功，无对 Spike 的悬空引用。

- [x] **Step 8：写验收清单文档并勾选 tasks.md**

`docs/superpowers/plans/e2e-checklist-ipad-codex-remote-client.md` 记录四场景的实测结果与录制帧归档位置。把 `openspec/changes/ipad-codex-remote-client/tasks.md` 中对应条目打勾。

- [x] **Step 9：全量测试 + Commit**

Run：`xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad (10th generation)'`
Expected：所有单测 PASS。

```bash
git add ios docs/superpowers/plans/e2e-checklist-ipad-codex-remote-client.md openspec/changes/ipad-codex-remote-client/tasks.md
git commit -m "test(e2e): verify connect/stream/resume/approval/reconnect; backfill fixtures; remove spike"
```

---

## 计划自检（Self-Review）

**1. Spec 覆盖核对：**
- `mac-launcher`（4 场景）→ Task 2 ✅
- `remote-connection`（握手/鉴权失败/不可达/重连/重连可见/Keychain）→ Task 3(spike)+6+7+8+10+11 ✅
- `conversation-streaming`（流式正文/命令输出/diff/steer/排队/不可steer/中断/图片/模型推理）→ Task 9+14+15+16+17 ✅
- `session-management`（按项目分组/恢复桌面会话/桌面来源可见/新建/徽标）→ Task 12+13+14 ✅
- `approval-flow`（命令审批/文件审批/legacy兼容/批准/前缀放行/拒绝/他端解决/超时断线不自动批准）→ Task 18+19 ✅

**2. Placeholder 扫描：** 各代码步骤均含完整可运行代码；字段名取自真实 schema；测试均含具体断言。唯一标注「以 spike/真实帧为准」处（exec stdio 换行分帧的读写细节、若干 notification 字段名）属设计 §13 明确留待 build 确认项，已在 Task 3/20 设校正点，非 placeholder。

**3. 类型一致性核对：** `ConnectionPhase`/`ConversationItem`/`ConversationState`/`UserInput`/`ApprovalChoice`/`CommandExecutionApprovalDecision`(v2) vs `ReviewDecision`(legacy) 在各任务间命名一致；`TurnStartParams.effort`（非 reasoningEffort）与 v2 schema 一致；`call` 方法在 Task 14 定义、Task 17 提升可见性已注明；`ComposerView(store:)` 签名在 Task 15/16 一致。

**核心约束落实确认：** build 首步 = Task 3 Citadel SSH exec proxy spike（最大风险前置）✅；协议从 generate 生成入仓库 + pin 0.133.0（Task 1）✅；五层分层（Task 4-13）✅；审批多选项 + v2 主 + legacy 兼容 + serverRequest/resolved + 超时不自动批准（Task 18/19）✅；协议层/归约层 fixture+mock 单测、SSH exec proxy 传输靠 spike+E2E（贯穿）✅。

**备选降级（风险兜底）：** 若 Citadel exec proxy 通道在 iPadOS 上不可行（spike 未通过），回退到旧方案 — Mac 端自起 `codex app-server --listen ws://127.0.0.1:<port>` + iPad 经 Citadel direct-tcpip 端口转发 + WebSocket 承载 JSON-RPC。主线必须是 exec proxy / stdio，此降级仅作 spike 失败时的备选路径。
