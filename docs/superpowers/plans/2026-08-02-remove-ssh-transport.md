---
change: remove-ssh-transport
design-doc: docs/superpowers/specs/2026-08-02-remove-ssh-transport-design.md
base-ref: bbee9d9210a88a9f4addf91421efe38337d0afde
---

# 移除 SSH 传输层全栈 实现计划（remove-ssh-transport）

> **给自动化执行者：** 必需子技能：用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 task 执行本计划。步骤用 checkbox（`- [ ]`）语法追踪。

**目标：** 移除 iOS app 的 SSH 传输层全栈，让 relay 成为唯一连接路径；app 未上线，不做存量迁移兼容。

**架构：** 严格按删除顺序：先把 relay 仍依赖的 `KeyStoring` 协议从待删的 `KeyManager.swift` 剪切到 survive 新文件（否则删 KeyManager 破坏 relay 编译并反引入 fail-open），再逐层删传输内核 → 安全模块 + Keychain 清理 → 机器模型 → 连接分派 → UI → 测试。Swift 编译器对任何残留 `KeyManager()` / `.ssh` / SSH 符号引用 hard-error，作为兜底 gate。

**技术栈：** Swift / SwiftUI / swift-crypto / XCTest / xcodegen + xcodebuild（iOS Simulator: iPad-Test）。

## Global Constraints

- 工作目录：`/Volumes/mount/codex-for-pados`；iOS 源码根 `ios/CodexRemote/`，测试根 `ios/CodexRemoteTests/`。
- isolation=worktree（base_ref `8b778a40`）；与并行 change A `connection-health-visibility` 谁先好谁先合、后者解冲突。
- pbxproj 由 xcodegen 从 `ios/project.yml` 生成；删/加文件后靠 `xcodegen generate`（build 脚本内含）同步引用，**不手改 `project.pbxproj`**。
- **编译命令**：`bash ios/comet-build-check.sh`（内部 `xcodegen generate` + `xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -quiet`）。
- **测试命令**：`cd ios && xcodegen generate >/dev/null && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData`（计数以 `xcrun xcresulttool` 权威读取）。
- **安全铁律（不可退让）**：relay 身份落盘 fail-closed（写失败必须 throw）；nil-relay 载荷结构性 throw、绝不回退明文/SSH；Keychain SSH 私钥 scoped delete，绝不误删 relay account `relay-e2e-identity-ed25519`。
- 每个 task 完成后：`tasks.md` 打勾 → git commit（不积攒）。
- 不动 relay E2E 栈实现；不改协议/daemon/dialout；不动 change A 的健康可视化。

---

## 文件结构（改动地图）

**新建**
- `ios/CodexRemote/Security/KeyStoring.swift` — 承接从 `KeyManager.swift` 剪切的 `protocol KeyStoring` + `extension KeyStoring`（`saveKeyThrowing` 默认转调）。relay 编译单元唯一依赖的 survive 文件。

**删除**
- `ios/CodexRemote/Transport/SSHClient.swift`、`Transport/ProxyChannel.swift`、`Transport/WSFrame.swift`、`Transport/DaemonBootstrap.swift`
- `ios/CodexRemote/Security/KeyManager.swift`（KeyStoring 迁出后）、`Transport/SSHHostKeyStore.swift`
- `ios/CodexRemote/Views/ConnectionConfigView.swift`
- 测试：`ios/CodexRemoteTests/SSHHostKeyStoreTests.swift`（+ `MachineConfigRelayMigrationTests.swift`，纯 SSH 迁移）

**修改**
- `ios/CodexRemote/CodexRemoteApp.swift`（启动加 SSH 私钥清理 hook）
- `Domain/MachineConfig.swift`（删 `ConnectionKind` enum，relay 字段内联）
- `Stores/MachineStore.swift`（删 `.ssh` minting）
- `Stores/ConnectionStore.swift`（`ConnectionConfig` 删 SSH 字段、删 SSH 分派）
- `App/LiveTransport.swift`（删 SSH 分支 + `makeSharedDaemonTransport`）
- `Transport/TransportError.swift`（删 `.sshAuthFailed`/`.proxyFailed`）
- `Views/MachineFormView.swift`（删 SSH 输入项 + `KeyManager`）
- `Domain/RelayPairingImportView.swift`（`.relay(...)` 构造改直接字段）
- 测试：`ConnectionStoreTests` / `MachineConfigTests` / `MachineFormViewTests` / `MachineStoreTests` / `KeychainStoreTests` / `ConnectionConfigLogicTests` / `KeyComboTests` 等清理 SSH 断言
- `ios/project.yml`（若显式列举文件则同步；默认 glob 由 xcodegen 自动处理）

---

## Task 0：解耦 KeyStoring 到 survive 新文件（BLOCKER 前置，必须最先）

**Files:**
- Create: `ios/CodexRemote/Security/KeyStoring.swift`
- Modify: `ios/CodexRemote/Security/KeyManager.swift:1-18`（剪切协议 + extension 出去，文件其余暂留）
- Test: `ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift`（新增 throw 断言）

**Interfaces:**
- Produces: `protocol KeyStoring { func saveKey(_:Data); func saveKeyThrowing(_:Data) throws; func loadKey() -> Data?; func deleteKey() }` + `extension KeyStoring { func saveKeyThrowing(_ value: Data) throws { saveKey(value) } }` —— 语义与位置除文件名外完全不变，同 target internal 可见。
- Consumes（下游不改）：`RelayE2EKeychainStore: KeyStoring`（`Security/RelayE2EKeyManager.swift:7`），其 `saveKeyThrowing` override 真抛写失败，**一行不改**。

- [ ] **Step 1：新建 `KeyStoring.swift`，剪切协议 + extension**

把 `KeyManager.swift:1-18` 的下述内容整体移入新文件（保留注释原文，锁死 throw 语义说明）：

```swift
import Foundation

/// 连接密钥的存储抽象：生产实现走 Keychain，测试可注入内存替身。
/// 仅存私钥 rawRepresentation（32 字节）的二进制，不做格式约定。
protocol KeyStoring {
    func saveKey(_ value: Data)
    /// 可抛版本：默认转调 saveKey（SSH 侧零改动、不抛）。需要真实反馈写失败的实现（relay）可 override。
    func saveKeyThrowing(_ value: Data) throws
    func loadKey() -> Data?
    func deleteKey()
}

extension KeyStoring {
    /// 默认实现：静默保存语义，不抛。需要真实反馈写失败的实现（relay）override 为真抛。
    func saveKeyThrowing(_ value: Data) throws { saveKey(value) }
}
```

- [ ] **Step 2：从 `KeyManager.swift` 删除已迁出的 `protocol KeyStoring` + `extension KeyStoring`**

删除 `KeyManager.swift:6-18`（协议 + extension 两段），保留文件顶部 import 与其余 `KeychainKeyStore` / `KeyManager` 定义原样（本 task 不删整文件，仅解耦；整文件删除在 Task 4）。

- [ ] **Step 3：写 relay 身份落盘 fail-closed 断言测试**

在 `RelayE2EKeyManagerTests.swift` 追加（用一个写必失败的 KeychainStore 替身触发 `saveKeyThrowing`）：

```swift
func test_relayIdentity_saveKeyThrowing_propagatesWriteFailure() {
    // 底层 keychain.save 抛错时，RelayE2EKeychainStore.saveKeyThrowing 必须继续 throw，
    // 而非吞掉 —— 锁死 relay 身份落盘 fail-closed，防未来回归为 fail-open。
    let failing = FailingKeychainStore()          // save(_:for:) 恒抛
    let store = RelayE2EKeychainStore(keychain: failing)
    XCTAssertThrowsError(try store.saveKeyThrowing(Data([0x01, 0x02])))
}
```

若测试目标暂无 `FailingKeychainStore` 替身，就近在本测试文件内定义：`save` throws，`load`/`delete` 返回空/无操作。

- [ ] **Step 4：编译 + 跑 relay 相关测试，验证解耦成功**

Run: `bash ios/comet-build-check.sh`
Expected: PASS（relay 栈 `RelayE2EKeyManager` 只依赖新 `KeyStoring.swift`，编译通过）
Run: `cd ios && xcodegen generate >/dev/null && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/RelayE2EKeyManagerTests`
Expected: PASS，含新 `test_relayIdentity_saveKeyThrowing_propagatesWriteFailure` 绿。

- [ ] **Step 5：提交**

```bash
git add ios/CodexRemote/Security/KeyStoring.swift ios/CodexRemote/Security/KeyManager.swift ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift
git commit -m "refactor(security): 解耦 KeyStoring 到 survive 文件，锁死 relay 身份落盘 fail-closed"
```

---

## Task 1：删 SSH 传输内核（4 文件闭合子图）

**Files:**
- Delete: `ios/CodexRemote/Transport/SSHClient.swift`（含 `SSHClientWrapper` + `SSHHostKeyStoring` 消费）
- Delete: `ios/CodexRemote/Transport/ProxyChannel.swift`
- Delete: `ios/CodexRemote/Transport/WSFrame.swift`（仅 ProxyChannel 用）
- Delete: `ios/CodexRemote/Transport/DaemonBootstrap.swift`（零引用死代码，位于 `Transport/`）

**Interfaces:**
- Consumes: 无（这是 relay 零依赖的闭合子图；对下游的引用点在 Task 4/5 才编辑删除，故本 task 编译会暂时报错，属预期，靠 grep 确认删除完整即可）。

- [ ] **Step 1：删除 4 个文件**

```bash
cd ios/CodexRemote/Transport
rm SSHClient.swift ProxyChannel.swift WSFrame.swift DaemonBootstrap.swift
```

- [ ] **Step 2：grep 确认这些文件内定义的符号在生产源码里只剩下游消费点**

Run: `cd ios/CodexRemote && grep -rnE 'SSHClientWrapper|ProxyChannel|WSFrame|DaemonBootstrap' . --include='*.swift'`
Expected: 无匹配（若有，是遗漏的定义/引用，须一并处理）。

- [ ] **Step 3：commit（此时全量编译尚未绿，属预期）**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Transport
git commit -m "refactor(transport): 删 SSH 传输内核（SSHClient/ProxyChannel/WSFrame/DaemonBootstrap）"
```

---

## Task 2：删 SSH 安全模块 + Keychain SSH 私钥一次性清理

**Files:**
- Modify: `ios/CodexRemote/CodexRemoteApp.swift`（启动路径加清理 hook）
- Delete: `ios/CodexRemote/Security/KeyManager.swift`（KeyStoring 已在 Task 0 迁出）
- Delete: `ios/CodexRemote/Transport/SSHHostKeyStore.swift`（含 `SSHHostKeyStoring` 协议 + `KeychainSSHHostKeyStore`；唯一消费者 `SSHClient` 已删）

**Interfaces:**
- Consumes: `KeychainStore().delete(_:for:)`（现有 API；SSH 私钥 account `ssh-ed25519-private-key`，service `com.codexremote.ssh`）。

- [ ] **Step 1：在 app 启动路径加极小 SSH 私钥清理 hook**

在 `CodexRemoteApp.swift` 启动最早处（`init()` 或首个 `.onAppear` 之前的一次性入口）加入幂等清理，account/service 精确 scoped：

```swift
/// 一次性清理旧 SSH 私钥（SSH 传输层已移除）。幂等、非阻断：
/// errSecItemNotFound = 已清理成功；其它错误仅记日志，不 fail-closed 阻断启动
///（清理失败不比保留现状更差）。account/service 精确 scoped，绝不误删 relay 密钥。
private static func purgeLegacySSHKeyOnce() {
    do {
        try KeychainStore().delete("ssh-ed25519-private-key")
    } catch {
        // 非 not-found 的错误仅记录，不阻断启动
        NSLog("purgeLegacySSHKey: %@", String(describing: error))
    }
}
```

在启动入口调用一次 `Self.purgeLegacySSHKeyOnce()`。若 `KeychainStore().delete` 对 not-found 已内部吞掉，则 do/catch 只兜其它错误。

- [ ] **Step 2：删除 2 个安全模块文件**

```bash
cd ios/CodexRemote
rm Security/KeyManager.swift Transport/SSHHostKeyStore.swift
```

- [ ] **Step 3：grep 确认 SSH host key 符号零残留、relay TOFU 独立**

Run: `cd ios/CodexRemote && grep -rnE 'SSHHostKeyStoring|KeychainSSHHostKeyStore|SSHHostKeyStore' . --include='*.swift'`
Expected: 无匹配（`TOFUStore`/`TOFUStoring` 是 relay 独立组件，不应出现在此 grep 中，确认无引用）。

- [ ] **Step 4：commit（此时 `KeyManager()` 下游消费点仍未删，编译暂不绿，属预期）**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Security ios/CodexRemote/Transport/SSHHostKeyStore.swift ios/CodexRemote/CodexRemoteApp.swift
git commit -m "refactor(security): 删 KeyManager/SSHHostKeyStore + 启动清理旧 SSH 私钥"
```

---

## Task 3：收敛机器模型 MachineConfig（删 ConnectionKind，relay 字段内联）

**Files:**
- Modify: `ios/CodexRemote/Domain/MachineConfig.swift`（多处，见下）
- Modify: `ios/CodexRemote/Domain/RelayPairingImportView.swift:57-59`（`.relay(...)` 构造改直接字段）

**Interfaces:**
- Produces: `MachineConfig` 直接持有 relay 字段 `var relayURL: String`、`var sessionId: String`、`var devIdentityPubB64: String`（原 `ConnectionKind.relay` 关联值内联）；`var connectionConfig: ConnectionConfig` 只产 relay 形态。
- Consumes: `ConnectionConfig` 的 relay init（Task 5 会把 SSH 字段删掉；本 task 先按现有 relay 构造点写，Task 5 收敛后编译对齐）。

- [ ] **Step 1：删 `ConnectionKind` enum，把 relay 三字段内联进 `MachineConfig`**

删除 `MachineConfig.swift:9`（`enum ConnectionKind` 整块，含 `.ssh`/`.relay` case、`CodingKeys`、encode/decode）。把 `relayURL`/`sessionId`/`devIdentityPubB64` 作为 `MachineConfig` 直接存储属性；删除 `var connection: ConnectionKind`（:67）。

- [ ] **Step 2：删 SSH 便利 init + designated init 的 `.ssh` 逻辑**

- 删除 SSH 便利 init（:82-85，`host`/`user`/`sshPort`/`sockPath` 参数那个）。
- designated init 里删 `if case .ssh(let host, _, _, _) = connection { fallback = host }`（:76），displayName fallback 改为 relay 语义（如 `relayURL` 派生或空串）。

- [ ] **Step 3：删 legacy flat-format→`.ssh` 解码迁移 + SSH 兼容 shim**

- 删除自定义 decode 中 flat-format→`.ssh` 分支（:103-116 区，`decodeIfPresent` host/user/sshPort/sockPath → `.ssh(...)`），decode 只读 relay 字段。
- 删除 SSH 兼容 computed shim：`var host`（:134）、`var user`（:135）、`var sshPort`（:136）、`var sockPath`（:137）、`static func sockPath(forUser:)`（:140）。

- [ ] **Step 4：`var connectionConfig` switch 去 `.ssh`，只产 relay**

`MachineConfig.swift:146-155`：删 `case .ssh(...)` 分支（:148-149），去掉 switch，直接用内联字段构造 relay `ConnectionConfig`。

- [ ] **Step 5：`.relay(...)` 构造/匹配点改直接字段访问**

`RelayPairingImportView.swift:57-59`（及 grep 出的其它 `case .relay` / `.relay(` 构造点）改为对 `MachineConfig` relay 字段的直接赋值/读取。

Run: `cd ios/CodexRemote && grep -rnE '\.ssh|ConnectionKind|case .relay|\.relay\(' . --include='*.swift'`
Expected: 生产源码零匹配（测试文件的 SSH 断言留到 Task 7 清）。

- [ ] **Step 6：commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Domain
git commit -m "refactor(model): MachineConfig 收敛为 relay-only，删 ConnectionKind 内联字段"
```

---

## Task 4：收敛 MachineStore（删 `.ssh` minting，BLOCKER）

**Files:**
- Modify: `ios/CodexRemote/Stores/MachineStore.swift:65,85`

**Interfaces:**
- Consumes: Task 3 收敛后的 relay-only `MachineConfig`。

- [ ] **Step 1：删 `migrateLegacyIfNeeded()` 的 `.ssh` minting**

`MachineStore.swift:85` 的 `migrateLegacyIfNeeded()`：删除 mint `.ssh` `MachineConfig` 的逻辑（引用已删 case 否则不编译）。若整函数除 `.ssh` minting 外无其它职责，删整函数并去掉 `:24` 的 `if machines.isEmpty { migrateLegacyIfNeeded() }` 调用点。

- [ ] **Step 2：确认 decode（:65）在无 `.ssh` 数据下 relay 机器持久化/恢复正常**

保持 decode 现状，不新增迁移代码（履行"当新 app"定调）。开发期模拟器脏 `.ssh` 数据视为一次性丢弃。

- [ ] **Step 3：全量编译（此时应首次转绿）**

Run: `bash ios/comet-build-check.sh`
Expected: PASS —— 编译器已 100% 抓过所有残留 `KeyManager()`/`.ssh`/SSH 符号；仍报错则回到对应 Task 补删。

- [ ] **Step 4：commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Stores/MachineStore.swift
git commit -m "refactor(store): MachineStore 删 .ssh minting，relay-only 持久化"
```

---

## Task 5：收敛连接分派（ConnectionStore / LiveTransport / TransportError）

**Files:**
- Modify: `ios/CodexRemote/Stores/ConnectionStore.swift:12-38,158`
- Modify: `ios/CodexRemote/App/LiveTransport.swift:9-15,69-92`
- Modify: `ios/CodexRemote/Transport/TransportError.swift`

**Interfaces:**
- Produces: `ConnectionConfig` 删除 SSH 字段（`host`/`user`/`sshPort`/`controlSockPath`）后只余 relay 载荷；`isRelay` 塌缩（恒真）或删除。`liveTransportFactory(_:) async throws -> MessageTransport` 只走 relay 分支，nil-relay 载荷结构性 throw（fail-closed）。
- Consumes: `RelayE2EKeyManager()`（`LiveTransport.swift:56`，relay 分支，不动）。

- [ ] **Step 1：`ConnectionConfig` 删 SSH 字段**

`ConnectionStore.swift:12-38`：删 `var host`（:15）、`var user`、`var sshPort`（:17）、`var controlSockPath`（:18）及相关 init（:30、:36-38）。更新注释（:12-13、:20）为 relay-only 语义。

- [ ] **Step 2：删 SSH 分派分支 + `KeyManager().hasKey`；`isRelay` 塌缩**

`ConnectionStore.swift`：删 `KeyManager().hasKey`（:158）；删按 `isRelay` 的 SSH 分派分支；gating 只校验 relay 载荷非空（`relayURL`/`sessionId`/`devIdentityPubB64` 非空）。

- [ ] **Step 3：`liveTransportFactory` 删 SSH else 分支 + `makeSharedDaemonTransport`**

`LiveTransport.swift`：删 `makeSharedDaemonTransport`（:9-15，唯一 SSH transport 构造）；`liveTransportFactory`（:72）删 else 分支（`KeyManager().privateKey()` @:89、`throw TransportError.sshAuthFailed` @:90）；只留 relay 分支；relay 载荷缺失时结构性 throw（保留 fail-closed，不回退 SSH/明文）。

- [ ] **Step 4：`TransportError` 删 SSH case**

`TransportError.swift`：删 `.sshAuthFailed`、`.proxyFailed` case 及其 message/描述分支。

- [ ] **Step 5：编译 + grep 二次确认零 SSH 生产符号**

Run: `bash ios/comet-build-check.sh`
Expected: PASS
Run: `cd ios/CodexRemote && grep -rnE 'SSHClient|ProxyChannel|sshPort|SSHHostKey|makeSharedDaemonTransport|sshAuthFailed|proxyFailed|KeyManager\(\)' . --include='*.swift'`
Expected: 生产源码零匹配。

- [ ] **Step 6：commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemote/App/LiveTransport.swift ios/CodexRemote/Transport/TransportError.swift
git commit -m "refactor(dispatch): 连接分派收敛为 relay-only，删 SSH fallback（保 fail-closed）"
```

---

## Task 6：收敛 UI（MachineFormView 删 SSH 项 + 删 ConnectionConfigView）

**Files:**
- Modify: `ios/CodexRemote/Views/MachineFormView.swift:14-20,44,50,70,79,110-130,202-211`
- Delete: `ios/CodexRemote/Views/ConnectionConfigView.swift`

**Interfaces:**
- Consumes: relay 配对导入路径（`RelayPairingImportView`，已存在）。

- [ ] **Step 1：`MachineFormView` 删 SSH 输入项 + KeyManager**

删除 `@State host/user/sshPort`（:14-16）、`@State keyManager = KeyManager()`（:20）、`.onAppear { keyManager.generateIfNeeded() }`（:79）；删 `Mode.ssh` tag（:44）与 `if mode == .ssh` 分支（:50、:70）；删 host/user/port 卡片输入框（:110-130）；删 `.ssh` `MachineConfig` 构造（:202-211）。`canSave`（:26-33）改为 relay 载荷判定。仅保留 relay 配对导入路径。

- [ ] **Step 2：删除 `ConnectionConfigView.swift`**

```bash
rm ios/CodexRemote/Views/ConnectionConfigView.swift
```

- [ ] **Step 3：确认无 `ConnectionConfigView` 调用点残留**

Run: `cd ios/CodexRemote && grep -rn 'ConnectionConfigView' . --include='*.swift'`
Expected: 无 struct 引用/构造点（已确认原仅 MachineFormView 注释提及 + 自身定义；若注释残留可顺手清）。

- [ ] **Step 4：编译**

Run: `bash ios/comet-build-check.sh`
Expected: PASS

- [ ] **Step 5：commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemote/Views
git commit -m "refactor(ui): MachineFormView relay-only + 删 ConnectionConfigView"
```

---

## Task 7：清理测试

**Files:**
- Delete: `ios/CodexRemoteTests/SSHHostKeyStoreTests.swift`、`ios/CodexRemoteTests/MachineConfigRelayMigrationTests.swift`（纯 SSH→relay 迁移，已无迁移路径）
- Modify: `ConnectionStoreTests` / `MachineConfigTests` / `MachineFormViewTests` / `MachineStoreTests` / `KeychainStoreTests` / `ConnectionConfigLogicTests` / `KeyComboTests` 等 SSH 断言/构造

**Interfaces:**
- Consumes: relay-only 的 `MachineConfig` / `ConnectionConfig` / `MachineFormView.canSave`。

- [ ] **Step 1：删 SSH-only 测试文件**

```bash
cd ios/CodexRemoteTests
rm SSHHostKeyStoreTests.swift MachineConfigRelayMigrationTests.swift
```

（若 `KeyManager` 相关断言散落在其它文件而非独立 `KeyManagerTests.swift`，就地删除对应用例，见 Step 2。）

- [ ] **Step 2：清理各测试文件的 SSH 断言/构造**

逐文件删除对 `.ssh(...)` 构造、`host`/`user`/`sshPort`/`sockPath`/`controlSockPath`、`KeyManager()`、`sshAuthFailed`/`proxyFailed` 的断言与替身；relay 场景断言保留。逐 grep 定位：

Run: `cd ios/CodexRemoteTests && grep -rnE '\.ssh|sshPort|KeyManager\(|sshAuthFailed|proxyFailed|controlSockPath|SSHClient|ProxyChannel' . --include='*.swift'`
Expected: 修完后仅剩 relay/无关匹配（理想为零）。

- [ ] **Step 3：确认 relay 测试未受影响**

`RelayE2EKeyManagerTests`（含 Task 0 新增 throw 断言）/ `RelayFactoryTests` / `RelayHandshakeTests` / `TOFUStoreTests` 等不改。

- [ ] **Step 4：全量测试**

Run: `cd ios && xcodegen generate >/dev/null && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData`
Expected: 全绿；用 `xcrun xcresulttool` 读权威计数确认无静默跳过。

- [ ] **Step 5：commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A ios/CodexRemoteTests
git commit -m "test: 清理 SSH 断言/替身，保留 relay 测试全绿"
```

---

## Task 8：验证（编译 gate + relay 冒烟 + 安全回归）

**Files:** 无新增改动（纯验证；发现残留则回对应 Task 修）。

- [ ] **Step 1：编译 gate + grep 二次确认零生产 SSH 符号**

Run: `bash ios/comet-build-check.sh`
Expected: PASS
Run: `cd ios/CodexRemote && grep -rnE 'SSHClient|ProxyChannel|sshPort|SSHHostKey|KeyManager\(\)|makeSharedDaemonTransport|ConnectionConfigView|sshAuthFailed|proxyFailed' . --include='*.swift'`
Expected: 零匹配。

- [ ] **Step 2：测试 gate（权威计数）**

Run: `cd ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData`
Expected: 全量绿；`RelayE2EKeyManagerTests.test_relayIdentity_saveKeyThrowing_propagatesWriteFailure` 绿。用 `xcrun xcresulttool get --path <result.xcresult>` 核对通过/失败/跳过计数。

- [ ] **Step 3：relay 冒烟（模拟器）**

在 iPad 模拟器经 relay 配对导入建连、收发一轮消息正常。记录结果（真机验收项归入本地清单，非本 change 阻断项）。

- [ ] **Step 4：安全回归复核**

逐条确认：
- nil-relay 载荷 → `liveTransportFactory` 结构性 throw，无 SSH/明文回退（fail-closed）。
- Keychain SSH 私钥（account `ssh-ed25519-private-key` @ service `com.codexremote.ssh`）已由启动 hook 清理；relay account `relay-e2e-identity-ed25519` 未受影响。
- relay 身份落盘写失败仍 throw（Task 0 断言绿背书）。

- [ ] **Step 5：勾选 `openspec/changes/remove-ssh-transport/tasks.md` 全部条目并 commit**

```bash
cd /Volumes/mount/codex-for-pados
git add -A openspec/changes/remove-ssh-transport/tasks.md
git commit -m "chore(remove-ssh-transport): 验证通过，勾选 tasks"
```

---

## Self-Review（对照 Design Doc 覆盖）

- **§0 KeyStoring 解耦** → Task 0（含 throw fail-closed 断言）。✅ 前置最先。
- **§1 删 SSH 传输内核 4 文件** → Task 1。✅
- **§2 Keychain 清理 + 删 KeyManager/SSHHostKeyStore** → Task 2。✅（启动 hook 幂等非阻断）
- **§3 MachineConfig 内联 + MachineStore 删 minting** → Task 3 + Task 4（BLOCKER）。✅
- **§4 ConnectionStore/LiveTransport/TransportError** → Task 5。✅（fail-closed 保留）
- **§5 MachineFormView + 删 ConnectionConfigView** → Task 6。✅
- **§6 清理测试** → Task 7。✅
- **§7 验证（编译 gate + relay 冒烟 + 安全回归）** → Task 8。✅
- **2 个 BLOCKER**：KeyStoring 前置（Task 0）、MachineStore `.ssh` minting（Task 4）均已排入正确顺序。✅
- **编译 gate 策略**：Task 1/2 后编译暂不绿属预期（下游消费点尚未删），Task 4 首次转绿，Task 5/6/8 逐次复核 + grep 兜底。✅
- **pbxproj**：靠 xcodegen 自动同步，无手改 dangling 引用风险。✅
