---
change: review-fixes-security-energy
design-doc: docs/superpowers/specs/2026-07-30-review-fixes-security-energy-design.md
base-ref: b28103cbe20e10e3dbe1f40c54292f56be99fb46
archived-with: 2026-08-01-review-fixes-security-energy
---

# review-fixes-security-energy 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务执行本计划。所有步骤用复选框（`- [ ]`）语法跟踪。

**目标（Goal）：** 修复一次跨端代码审查报告的 8 处属实缺陷（4 处安全 fail-open + 4 处能耗/生命周期空转），全部为最小防御性收口，无协议/架构变更。

**架构（Architecture）：** 8 组缺陷互不依赖，每组 = 一个独立提交、可单独回滚。安全 4 组（#1/#2/#5/#8）走 fail-closed + 最小暴露；能耗 4 组（#3/#4/#6/#7）走后台暂停 + 避免空转 + 重连有界。所有并发路径复用既有模式（`ConnectionStore` 的 take-and-nil + attempt-token；`RelayE2EKeyManager` 镜像 `KeyManager` 的 `KeyStoring` 注入）。relay 协议**不 bump**，新旧端兼容。

**技术栈（Tech Stack）：** Swift / SwiftUI（iOS app，Xcode target，xcodegen 生成——`Bundle.module` 不可用）；Swift Package（relay-dialout / RelayDialoutCore）；CryptoKit；AVFoundation；SwiftTerm。测试框架两种并存：iOS 侧 `XCTest`（多数 Store/安全测试）与 Swift Testing `@Test`（Terminal 等）；relay-dialout 侧统一 Swift Testing `@Test`。

## 全局约束（Global Constraints）

- **base-ref**：master `b28103cbe20e10e3dbe1f40c54292f56be99fb46`。所有改动以此为基线。
- **canonical spec**：验收边界以 `openspec/changes/review-fixes-security-energy/specs/` 下 4 份 delta spec 的 Scenario 为准，不改写验收场景。
- **安全铁律**：fail-closed 不 fail-open；最小暴露；职责分离（relay 密钥路径改动**绝不**触及 SSH `KeyManager`）。
- **能耗铁律**：后台暂停、避免空转、重连有界（指数退避 + 硬上限）。
- **提交纪律（comet build）**：每组缺陷完成后 → 勾选 `openspec/changes/review-fixes-security-energy/tasks.md` 对应项 → 立即 `git commit`（不积攒）。每组一个提交。
- **测试替身惯例**：iOS 内存 `KeyStoring` 替身叫 `MemoryKeyStore`；`MockTransport` / `CloseSpyTransport` / `ControlEmittingTransport` 已存在于 `ios/CodexRemoteTests/`，复用勿重造；relay-dialout 握手驱动复用 `DialoutTrustHarness` 模式。
- **收尾门槛**：四个 Swift Package 测试全绿 + iPad 模拟器全量测试全绿 + `xcodebuild analyze` 通过（见 Task 9）。

---

## 文件结构（File Structure）

按 8 组缺陷划分，每组触碰的文件：

| 组 | 生产文件 | 测试文件 |
|----|----------|----------|
| #1 剪贴板门控 | `ios/CodexRemote/App/AppearanceManagers.swift`（新增 `ClipboardPolicyStore`，与既有 manager 同文件同风格）；`ios/CodexRemote/App/CodexRemoteApp.swift`（注入）；`ios/CodexRemote/Views/Settings/SettingsSection.swift` +（新增）`PrivacySettingsSectionView.swift` + `SettingsPageView.swift`（新分区）；`ios/CodexRemote/Views/Workspace/SwiftTermView.swift`（读开关 + 上限）；`ios/CodexRemote/Views/Workspace/BottomPanelView.swift`（传注入） | `ios/CodexRemoteTests/ClipboardPolicyTests.swift`（新增） |
| #2 dev 落盘后发布 | `relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift`；`relay-dialout/Sources/relay-dialout/main.swift` | `relay-dialout/Tests/RelayDialoutCoreTests/DialoutContextTrustTests.swift`（追加） |
| #5 iPad 密钥落盘后缓存 | `ios/CodexRemote/Security/KeyManager.swift`（`KeyStoring` 加带默认实现的 `saveKeyThrowing`）；`ios/CodexRemote/Security/RelayE2EKeyManager.swift`（override + `identityKey() throws`）；`ios/CodexRemote/App/LiveTransport.swift`（调用点改 `try`） | `ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift`（追加） |
| #8 dev 加载校验权限 | `relay-dialout/Sources/RelayDialoutCore/DevKeyStore.swift` | `relay-dialout/Tests/RelayDialoutCoreTests/DevKeyStoreTests.swift`（追加） |
| #3 空闲攒批按需 | `ios/CodexRemote/Stores/ConversationStore.swift` | `ios/CodexRemoteTests/ConversationCoalesceSchedulingTests.swift`（新增） |
| #4 相机启停串行 | `ios/CodexRemote/Views/QRScannerView.swift` | `ios/CodexRemoteTests/QRScannerLifecycleTests.swift`（新增，测状态机逻辑） |
| #6 侧栏可见性轮询 | `ios/CodexRemote/Views/SidebarView.swift`；`ios/CodexRemote/Stores/ProjectsStore.swift` | `ios/CodexRemoteTests/ProjectsPollingTests.swift`（追加） |
| #7 后台暂停首连 | `ios/CodexRemote/Stores/ConnectionStore.swift` | `ios/CodexRemoteTests/ConnectionStoreTests.swift`（追加） |

---

## Task 1（#1）：终端 OSC 52 剪贴板写门控（安全）

**对应 tasks.md：** 1.1 / 1.2 / 1.3 ｜ **验收 spec：** `specs/ipad-bottom-terminal/spec.md`（4 个 Scenario：开关关不改剪贴板 / 开且限内写入 / 开但超限拒写 / 读方向始终 nil）

**Files:**
- Modify: `ios/CodexRemote/App/AppearanceManagers.swift`（末尾新增 `ClipboardPolicyStore`）
- Modify: `ios/CodexRemote/App/CodexRemoteApp.swift:8-31`（新增 `@State` + `.environment` 注入）
- Modify: `ios/CodexRemote/Views/Settings/SettingsSection.swift:5-39`（新增 `.privacy` 分区）
- Create: `ios/CodexRemote/Views/Settings/PrivacySettingsSectionView.swift`
- Modify: `ios/CodexRemote/Views/Settings/SettingsPageView.swift:40-46`（detail switch 增分支）
- Modify: `ios/CodexRemote/Views/Workspace/SwiftTermView.swift:24-115`（读开关 + 64KB 上限）
- Modify: `ios/CodexRemote/Views/Workspace/BottomPanelView.swift:19`（把策略传进 `SwiftTermView`）
- Test: `ios/CodexRemoteTests/ClipboardPolicyTests.swift`（新增）

**Interfaces:**
- Produces：
  - `@Observable final class ClipboardPolicyStore`，持久化键 `"clipboard_allow_remote_write"`（`UserDefaults`），属性 `var allowRemoteWrite: Bool`（默认 `false`），常量 `static let maxWriteBytes = 64 * 1024`，纯函数 `func shouldWrite(byteCount: Int) -> Bool { allowRemoteWrite && byteCount <= Self.maxWriteBytes }`。
  - `SwiftTermView` 新增存储属性 `let clipboardPolicy: ClipboardPolicyStore`；`Coordinator` 持有它。
- Consumes：`SettingsPageView` 通过 `@Environment(ClipboardPolicyStore.self)`；`BottomPanelView` 通过 `@Environment(ClipboardPolicyStore.self)` 读取并传入。

**锁定决策（来自 Design Doc §一）：** 单次写入上限 = 64KB（`64 * 1024` 字节），超限**拒写不截断**；设置项默认**关闭**；`clipboardRead` 维持返回 `nil` 不受开关影响；iPad→终端输入方向不动。

- [x] **Step 1：写失败测试（策略纯逻辑）**

新建 `ios/CodexRemoteTests/ClipboardPolicyTests.swift`，参照 `SettingsSectionViewLogicTests` 的注入式 `UserDefaults` 隔离写法：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ClipboardPolicyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClipboardPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    func testDefaultIsOffSoNeverWrites() {
        let p = ClipboardPolicyStore(store: defaults)
        XCTAssertFalse(p.allowRemoteWrite)                 // 默认关闭
        XCTAssertFalse(p.shouldWrite(byteCount: 1))        // 关 → 一律拒写
    }

    func testOnAndWithinLimitWrites() {
        let p = ClipboardPolicyStore(store: defaults)
        p.allowRemoteWrite = true
        XCTAssertTrue(p.shouldWrite(byteCount: 64 * 1024))       // 恰好上限内
        XCTAssertFalse(p.shouldWrite(byteCount: 64 * 1024 + 1))  // 超一字节拒写
    }

    func testTogglePersists() {
        let p = ClipboardPolicyStore(store: defaults)
        p.allowRemoteWrite = true
        XCTAssertTrue(ClipboardPolicyStore(store: defaults).allowRemoteWrite)  // 重建仍为 true
    }
}
```

- [x] **Step 2：跑测试确认失败**

Run: iOS 测试 target 跑 `ClipboardPolicyTests`（Xcode 或 `xcodebuild test ... -only-testing:CodexRemoteTests/ClipboardPolicyTests`）
Expected: 编译失败（`ClipboardPolicyStore` 未定义）。

- [x] **Step 3：实现 `ClipboardPolicyStore`**

在 `ios/CodexRemote/App/AppearanceManagers.swift` 末尾追加（与 `ThemeManager` 同风格：注入式 `UserDefaults` + `didSet` 持久化）：

```swift
// MARK: - 剪贴板写门控（#1 安全）

/// 远端终端 OSC 52 写系统剪贴板的门控开关。默认关闭（fail-closed）。
/// 持久化键 "clipboard_allow_remote_write"；单次写入上限 64KB（超限拒写、不截断）。
@Observable
final class ClipboardPolicyStore {
    private let store: UserDefaults
    private static let key = "clipboard_allow_remote_write"
    /// 单次写入字节上限：正常终端复制的命令/路径/代码远小于此。
    static let maxWriteBytes = 64 * 1024

    var allowRemoteWrite: Bool {
        didSet { store.set(allowRemoteWrite, forKey: Self.key) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        self.allowRemoteWrite = store.bool(forKey: Self.key)   // 缺省 false = 默认关闭
    }

    /// 是否允许本次写入：开关开 且 未超上限。
    func shouldWrite(byteCount: Int) -> Bool {
        allowRemoteWrite && byteCount <= Self.maxWriteBytes
    }
}
```

- [x] **Step 4：跑测试确认通过**

Run: `ClipboardPolicyTests`
Expected: 3 个用例全 PASS。

- [x] **Step 5：接线 `SwiftTermView.clipboardCopy` 应用门控**

改 `ios/CodexRemote/Views/Workspace/SwiftTermView.swift`。给 `SwiftTermView` 与 `Coordinator` 注入策略：

`struct SwiftTermView` 顶部（:25 `let session` 旁）加：
```swift
    let clipboardPolicy: ClipboardPolicyStore
```
`makeCoordinator()`（:28）改为：
```swift
    func makeCoordinator() -> Coordinator { Coordinator(session: session, clipboardPolicy: clipboardPolicy) }
```
`Coordinator`（:74-82）加存储属性与初始化：
```swift
        let session: TerminalSession
        let bridge: TerminalBridge
        let clipboardPolicy: ClipboardPolicyStore
        weak var terminalView: TerminalView?

        init(session: TerminalSession, clipboardPolicy: ClipboardPolicyStore) {
            self.session = session
            self.bridge = TerminalBridge(session: session)
            self.clipboardPolicy = clipboardPolicy
        }
```
`clipboardCopy`（:100-104）改为门控 + 上限：
```swift
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                // #1：默认 fail-closed。开关关 → 静默丢弃；开 → 校验单次 ≤64KB（超限拒写、不截断）。
                guard clipboardPolicy.shouldWrite(byteCount: content.count) else { return }
                UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
            }
        }
```
`clipboardRead`（:111）**不动**（维持 `nil`）。

- [x] **Step 6：`BottomPanelView` 传入策略**

改 `ios/CodexRemote/Views/Workspace/BottomPanelView.swift`：顶部（:8 `@Environment(TerminalSession.self)` 旁）加 `@Environment(ClipboardPolicyStore.self) private var clipboardPolicy`；:19 改为 `SwiftTermView(session: terminal, clipboardPolicy: clipboardPolicy)`。

- [x] **Step 7：根部创建并注入 `ClipboardPolicyStore`**

改 `ios/CodexRemote/App/CodexRemoteApp.swift`：在 :15 `shortcuts` 旁加 `@State private var clipboardPolicy = ClipboardPolicyStore()`；在 :24 `.environment(shortcuts)` 后加 `.environment(clipboardPolicy)`。

- [x] **Step 8：新增「隐私」设置分区并接线**

改 `ios/CodexRemote/Views/Settings/SettingsSection.swift`：`enum` 加 `case privacy`（放 `.appearance` 后）；`label` 加 `case .privacy: return "settings.privacy"`；`icon` 加 `case .privacy: return "hand.raised"`。

新建 `ios/CodexRemote/Views/Settings/PrivacySettingsSectionView.swift`：
```swift
import SwiftUI

/// 隐私分区（#1）：远端终端写系统剪贴板门控。默认关闭。
struct PrivacySettingsSectionView: View {
    @Environment(ClipboardPolicyStore.self) private var clipboard

    var body: some View {
        @Bindable var clipboard = clipboard
        List {
            Section {
                Toggle("settings.privacy.allowRemoteClipboardWrite", isOn: $clipboard.allowRemoteWrite)
            } footer: {
                Text("settings.privacy.allowRemoteClipboardWrite.footer")
            }
        }
        .navigationTitle("settings.privacy")
    }
}
```
改 `ios/CodexRemote/Views/Settings/SettingsPageView.swift` detail switch（:40-46）加：`case .privacy: PrivacySettingsSectionView()`。

在 `ios/CodexRemote/Resources/Localizable.xcstrings` 补三个本地化键（`settings.privacy`、`settings.privacy.allowRemoteClipboardWrite`、`.footer`）中英值；中文示例：「隐私」/「允许远端写入剪贴板」/「关闭时，远端终端无法覆盖 iPad 系统剪贴板（防命令/凭据粘贴劫持）。开启后单次写入上限 64KB。」。

- [x] **Step 9：编译 + 全量测试 + analyze**

Run: 模拟器全量测试 + `xcodebuild analyze`。
Expected: `ClipboardPolicyTests` 绿；既有 `TerminalTests` 不回归（`SwiftTermView` 签名变更后确认 `BottomPanelView` 是唯一调用点已更新）。

- [x] **Step 10：勾选并提交**

勾选 tasks.md 1.1/1.2/1.3。
```bash
git add ios/CodexRemote/App/AppearanceManagers.swift ios/CodexRemote/App/CodexRemoteApp.swift \
  ios/CodexRemote/Views/Settings/SettingsSection.swift ios/CodexRemote/Views/Settings/PrivacySettingsSectionView.swift \
  ios/CodexRemote/Views/Settings/SettingsPageView.swift ios/CodexRemote/Views/Workspace/SwiftTermView.swift \
  ios/CodexRemote/Views/Workspace/BottomPanelView.swift ios/CodexRemote/Resources/Localizable.xcstrings \
  ios/CodexRemoteTests/ClipboardPolicyTests.swift openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#1): gate remote OSC52 clipboard write behind default-off toggle + 64KB cap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2（#2）：dev 侧信任落盘后再发布会话（安全）

**对应 tasks.md：** 2.1 / 2.2 / 2.3 ｜ **验收 spec：** `specs/relay-e2e-transport/spec.md` Requirement「dev 侧信任落盘成功后才发布会话与消费口令」（4 个 Scenario：落盘失败不发布 / 调用方不吞错不启 bridge / 落盘成功原子发布 / 受信任复连不回归）

**Files:**
- Modify: `relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift:133-178`（`handleClientAuth` 事务顺序）
- Modify: `relay-dialout/Sources/relay-dialout/main.swift:177`（去掉 `try?`）
- Test: `relay-dialout/Tests/RelayDialoutCoreTests/DialoutContextTrustTests.swift`（追加，Swift Testing `@Test`）

**Interfaces:**
- Consumes：既有 `TrustStore.trust(ipadPubB64:stableSessionId:label:) throws`（:43）；`DialoutContext.session`（:54）；`DialoutHandshakeError`。
- Produces：`handleClientAuth` 语义变为——首配路径下先 `trust.trust` 成功、后原子发布 `_session` + 置 `_pairingConsumed`；落盘失败抛错且 `_session` 保持 nil。

**锁定决策（来自 Design Doc §二）：** 仅调整**首次配对分支**「落盘 vs 发布」相对顺序（先落盘成功再发布）；**受信任复连（trusted）分支语义保持不变**；`main.swift:177` 去掉 `try?`，落盘失败不启 bridge（后续 SecureEnvelope 无已发布会话可命中）。

- [x] **Step 1：写失败注入替身（可控 throw 的 TrustStore 通道）**

`TrustStore` 是 `final class` 且无协议抽象；为注入「落盘失败」，最省的路径是构造一个**只读目录**让 `trust()` 的 `persist()` 写失败。在 `DialoutContextTrustTests.swift` 末尾追加：

```swift
/// #2：信任落盘失败时，handleClientAuth 必须向上抛错、不发布 _session、不消费口令。
@Test func trustPersistFailureDoesNotPublishSession() throws {
    let h = try DialoutTrustHarness()
    // 用一个 TrustStore 指向随后被设为只读的目录，令首配路径的 trust.trust 落盘失败。
    let trust = try TrustStore(dir: h.trustDir)
    // 把信任目录设为不可写（0500），使 persist() 的原子写抛错。
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: h.trustDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: h.trustDir.path) }

    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 pairingCode: h.pairingCode, expiresAt: h.expiresAt, trust: trust)
    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "room-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: h.ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: h.ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: h.pairingCode)
    let shData = try context.handleClientHello(JSONEncoder().encode(hello))
    let sh = try JSONDecoder().decode(ServerHello.self, from: shData)
    let auth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: sh,
        devIdentityPub: h.devKeyStore.identityPublicKeyRaw, ipadIdentity: h.ipadIdentity)

    // 落盘失败 → handleClientAuth 抛错。
    #expect(throws: (any Error).self) {
        _ = try context.handleClientAuth(JSONEncoder().encode(auth))
    }
    // 关键 fail-closed 见证：session 未发布、口令未消费。
    #expect(context.session == nil)
    #expect(context.pairingConsumed == false)
}
```

> 注：若目标平台以 root 跑测试（只读目录不阻止写），退化为把 `h.trustDir` 预先创建成一个**同名文件**（而非目录）使 `createDirectory`/写入抛错；执行者按实际环境择一，二选一都验证同一不变量。

- [x] **Step 2：跑测试确认失败**

Run: `swift test --package-path relay-dialout --filter trustPersistFailureDoesNotPublishSession`
Expected: FAIL —— 现实现先发布 `_session`（:162）再 `trust.trust`（:171），故 `context.session != nil`，断言 `session == nil` 失败。

- [x] **Step 3：调整 `handleClientAuth` 事务顺序（仅首配分支）**

改 `relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift:161-177`。把「记信任」提到「发布 session」之前，并保持受信任分支不变：

```swift
        // 稳定 sessionId：已受信任的 iPad 复用其记录值；首次配对新生成。每台 iPad 各一个。
        let ipadPub = hello.ipadIdentityPub.base64EncodedString()
        let stable = trust.record(forPubB64: ipadPub)?.stableSessionId ?? randomStableToken()

        // #2 事务性：先把信任落盘成功，之后才在锁内原子发布 _session + 消费一次性口令。
        // 落盘失败（IO/权限）→ 清握手态、向上抛，绝不发布已建但信任未落盘的会话。
        do {
            try trust.trust(ipadPubB64: ipadPub, stableSessionId: stable, label: nil)
        } catch {
            lock.lock(); _eph = nil; lock.unlock()   // 与验签失败路径一致：释放交换私钥，_session 保持 nil
            throw error
        }

        lock.lock()
        _session = session
        _eph = nil                                 // 握手完成即释放交换私钥
        if !trusted { _pairingConsumed = true }    // 仅首配消费一次性口令；受信任复连不置
        lock.unlock()

        // 构造并加密 SecureReady（走已建通道回传稳定 sessionId）。
        let ready = SecureReady(sessionId: hello.sessionId, keyEpoch: 0,
                                devDeviceId: devDeviceId, stableSessionId: stable)
        let env = try session.seal(JSONEncoder().encode(ready))
        return try env.encoded()
```

> 说明：验签成功后得到的 `session` 是局部量（:147-160 不变），此处仅把「写 `_session`」延后到 `trust.trust` 成功之后。`trusted` 分支下 `trust.trust` 对已有记录是幂等更新（`TrustStore.trust` :44-50），行为与改前一致，故受信任复连不回归。

- [x] **Step 4：调用方去掉 `try?`**

改 `relay-dialout/Sources/relay-dialout/main.swift:177`。现为 `if context.hellos != nil, let readyFrame = try? context.handleClientAuth(data) {`。改为显式 try + 失败不启 bridge：

```swift
        // 握手期：先试 ClientAuth（更晚），再试 ClientHello。
        // #2：不吞错——落盘失败必须冒泡，绝不因 try? 吞错而在信任未落盘时启 bridge。
        if context.hellos != nil {
            let readyFrame: Data
            do { readyFrame = try context.handleClientAuth(data) }
            catch {
                // 落盘/验签失败：不发 SecureReady、不启 bridge、不发布会话。关连接由上层错误路径处理。
                return
            }
            sendFrame(readyFrame, ctx: ctx)   // 只发一次
            ensureBridgeStarted()
            pumpBridgeOutbound(ctx: ctx)
            return
        }
```

> 注意保持原「先试 ClientAuth 再试 ClientHello」的语义：只有当 `context.hellos != nil`（已收过 ClientHello）时才尝试 ClientAuth。`catch` 里直接 `return`（不 fall through 到 ClientHello 解析），因为在 hellos 已就绪时一帧要么是合法 ClientAuth 要么无效——与改前 `try?` 失败后继续尝试 ClientHello 解码的行为等价（合法 ClientAuth 帧不会解成 ClientHello）。

- [x] **Step 5：跑新测试 + 既有信任测试确认全绿**

Run: `swift test --package-path relay-dialout --filter DialoutContextTrust`
Expected: 新用例 PASS；既有 `firstPairingRecordsTrustWithStableSessionId` / `handleClientAuthReturnsEncryptedSecureReady` / `handleClientAuthRejectsReplayOfSameFrame` / `repeatedPairingReusesSameStableSessionId` / `trustedRehandshakeOnSameContextIsIdempotent` 全部不回归（受信任复连幂等路径验收由 `trustedRehandshakeOnSameContextIsIdempotent` 覆盖）。

- [x] **Step 6：勾选并提交**

勾选 tasks.md 2.1/2.2/2.3。
```bash
git add relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift relay-dialout/Sources/relay-dialout/main.swift \
  relay-dialout/Tests/RelayDialoutCoreTests/DialoutContextTrustTests.swift openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#2): persist trust before publishing session; caller no longer swallows error

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3（#5）：iPad 身份密钥落盘成功后才缓存（安全）—— 方案 A（SSH 零改动）

**对应 tasks.md：** 3.1 / 3.2 / 3.3 ｜ **验收 spec：** `specs/relay-e2e-transport/spec.md` Requirement「iPad 身份密钥落盘成功后才缓存参与配对」（3 个 Scenario：写失败不缓存不配对 / 落盘成功缓存复用 / SSH 路径不受影响）

**Files:**
- Modify: `ios/CodexRemote/Security/KeyManager.swift:7-11`（`KeyStoring` 新增带默认实现的 `saveKeyThrowing`）
- Modify: `ios/CodexRemote/Security/RelayE2EKeyManager.swift:12-19,44-52`（override + `identityKey() throws`）
- Modify: `ios/CodexRemote/App/LiveTransport.swift:57`（`try e2e.identityKey()`）
- Test: `ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift`（追加）

**Interfaces:**
- Produces：
  - `KeyStoring` 新增 `func saveKeyThrowing(_ value: Data) throws`，**带 protocol extension 默认实现**：`{ saveKey(value) }`（调旧 `saveKey`，SSH 侧零改动、不抛）。
  - `RelayE2EKeychainStore` override `saveKeyThrowing` 为真实抛出（`try keychain.save(...)`，不吞错）。
  - `RelayE2EKeyManager.identityKey() throws -> Curve25519.Signing.PrivateKey`（签名从非 throws 变 throws）。
- Consumes：`KeychainStore.save(_:for:) throws`（:15，真实抛 `KeychainError.os`）。

**锁定决策（来自 Design Doc §三，方案 A）：** **不给 `saveKey` 加 throws、不碰 SSH `KeyManager`**。改为在 `KeyStoring` 加**带默认实现**的 `saveKeyThrowing`（默认转调旧 `saveKey`，SSH `KeychainKeyStore` 继承默认实现、行为不变）；仅 `RelayE2EKeychainStore` override 为真实抛出；`RelayE2EKeyManager.identityKey()` 改 throws，仅 `saveKeyThrowing` 成功后 `cachedIdentity = k` 并返回。身份为幂等复用（已存在不重存），不触发删旧身份场景。

- [x] **Step 1：写失败测试（注入会抛错的 store）**

改 `ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift`。文件顶部 `MemoryKeyStore`（:6-11）追加一个会抛错的替身，并新增用例：

```swift
/// 保存必失败的 store：验证 identityKey() 落盘失败时抛错、不缓存。
private struct ThrowingKeyStore: KeyStoring {
    struct WriteFailed: Error {}
    func saveKey(_ value: Data) {}                    // 默认实现不该被 identityKey 走到
    func saveKeyThrowing(_ value: Data) throws { throw WriteFailed() }
    func loadKey() -> Data? { nil }
    func deleteKey() {}
}
```

新增用例（放入 `RelayE2EKeyManagerTests`）：
```swift
    /// Keychain 写失败 → identityKey() 抛错、不缓存该密钥、配对以失败告终而非静默成功。
    func testIdentityKeyThrowsAndDoesNotCacheOnSaveFailure() {
        let m = RelayE2EKeyManager(store: ThrowingKeyStore())
        XCTAssertThrowsError(try m.identityKey())         // 落盘失败必抛
        XCTAssertThrowsError(try m.identityKey())         // 未缓存 → 再次仍抛（不会返回上次的“成功”密钥）
    }

    /// 落盘成功 → 缓存并幂等复用（重启从同一 store 重建拿同一身份）。
    func testIdentityKeyCachesAfterSuccessfulSave() throws {
        let store = MemoryKeyStore()
        let m1 = RelayE2EKeyManager(store: store)
        let pub1 = try m1.identityKey().publicKey.rawRepresentation
        let pub2 = try RelayE2EKeyManager(store: store).identityKey().publicKey.rawRepresentation
        XCTAssertEqual(pub1, pub2)
    }
```
同时把既有 `testIdentityKeyIsPersistentAndIdempotent`（:17-24）与 `testE2EAccountIsolatedFromSSHAccount`（:35-52）里的 `m.identityKey()` 调用改为 `try m.identityKey()`（用例签名加 `throws`）。

- [x] **Step 2：跑测试确认失败**

Run: `-only-testing:CodexRemoteTests/RelayE2EKeyManagerTests`
Expected: 编译失败（`saveKeyThrowing` 未定义、`identityKey()` 不 throws）。

- [x] **Step 3：`KeyStoring` 加带默认实现的 `saveKeyThrowing`**

改 `ios/CodexRemote/Security/KeyManager.swift:7-11`：
```swift
protocol KeyStoring {
    func saveKey(_ value: Data)
    /// 可抛版本：默认转调 saveKey（SSH 侧零改动、不抛）。需要真实反馈写失败的实现（relay）可 override。
    func saveKeyThrowing(_ value: Data) throws
    func loadKey() -> Data?
    func deleteKey()
}

extension KeyStoring {
    /// 默认实现：SSH（KeychainKeyStore）沿用旧的静默保存语义，不抛。
    func saveKeyThrowing(_ value: Data) throws { saveKey(value) }
}
```
`KeychainKeyStore`（SSH，:15-30）与 `KeyManager`（:38-112）**完全不动**（职责分离铁律）。

- [x] **Step 4：`RelayE2EKeychainStore` override 真实抛出 + `identityKey()` 改 throws**

改 `ios/CodexRemote/Security/RelayE2EKeyManager.swift`。`RelayE2EKeychainStore`（:7-20）加 override：
```swift
    func saveKey(_ value: Data) {
        try? keychain.save(value.base64EncodedString(), for: account)
    }
    /// #5：relay 身份写 Keychain 真实抛错（不吞），供 identityKey() 落盘确认。
    func saveKeyThrowing(_ value: Data) throws {
        try keychain.save(value.base64EncodedString(), for: account)
    }
```
`identityKey()`（:44-52）改为 throws + 落盘成功后才缓存：
```swift
    /// 身份私钥：无则生成并**确认持久化成功后**才缓存复用（幂等）。落盘失败抛错、不缓存、不参与配对。
    @discardableResult
    func identityKey() throws -> Curve25519.Signing.PrivateKey {
        if let k = cachedIdentity { return k }
        let k = Curve25519.Signing.PrivateKey()
        try store.saveKeyThrowing(k.rawRepresentation)   // 落盘失败 → 抛出，cachedIdentity 保持 nil
        cachedIdentity = k
        return k
    }
```
`identityPublicKeyRaw()`（:55）随之改 throws：
```swift
    func identityPublicKeyRaw() throws -> Data { try identityKey().publicKey.rawRepresentation }
```

- [x] **Step 5：调用点改 `try`**

改 `ios/CodexRemote/App/LiveTransport.swift:56-57`。`makeRelayTransport` 是 `async throws`（见 :85 调用处 `try await`），可直接向上抛：
```swift
    let e2e = RelayE2EKeyManager()
    let identity = try e2e.identityKey()   // 持久身份，跨重连复用；落盘失败则配对以明确失败告终
```
确认 `identityPublicKeyRaw()` 无其它调用点（`grep` 显示仅 `LiveTransport.swift:57` 用 `identityKey()`，`identityPublicKeyRaw` 在 iOS 侧无调用者——dev 侧的同名属性属 `DevKeyStore`，不受影响）。

- [x] **Step 6：跑测试确认通过 + SSH 不回归**

Run: `-only-testing:CodexRemoteTests/RelayE2EKeyManagerTests`
Expected: 新旧用例全绿。特别是 `testE2EAccountIsolatedFromSSHAccount` 证明 SSH account 未被触碰（SSH 路径不受影响 Scenario）。

- [x] **Step 7：勾选并提交**

勾选 tasks.md 3.1/3.2/3.3。
```bash
git add ios/CodexRemote/Security/KeyManager.swift ios/CodexRemote/Security/RelayE2EKeyManager.swift \
  ios/CodexRemote/App/LiveTransport.swift ios/CodexRemoteTests/RelayE2EKeyManagerTests.swift \
  openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#5): cache relay identity key only after Keychain persist confirmed (SSH untouched)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4（#8）：dev 加载已有私钥校验权限（安全）

**对应 tasks.md：** 4.1 / 4.2 / 4.3 ｜ **验收 spec：** `specs/relay-e2e-transport/spec.md` Requirement「dev 身份私钥文件加载前校验并收紧权限」（3 个 Scenario：0644 收紧/拒绝 / 属主不符 fail-closed / 符号链接被拒）

**Files:**
- Modify: `relay-dialout/Sources/RelayDialoutCore/DevKeyStore.swift:42-62`（`loadOrCreateIdentity` 加权限校验）
- Test: `relay-dialout/Tests/RelayDialoutCoreTests/DevKeyStoreTests.swift`（追加，Swift Testing `@Test`）

**Interfaces:**
- Produces：`DevKeyStore.DevKeyStoreError` 新增 `case insecureKeyFile(String)`（权限/属主/符号链接校验失败）。
- Consumes：`FileManager` / POSIX `lstat` / `getuid()`（`import Foundation` 已足够；符号链接判定用 `URL.resourceValues(forKeys: [.isSymbolicLinkKey])` 或 `lstat` + `S_ISLNK`）。

**锁定决策（来自 Design Doc §四，fail-closed）：** 读已存在文件前：`lstat` 拒绝符号链接（防经软链读受控外文件）→ 校验属主 == 当前 uid → `chmod` 收紧文件 0600、父目录 0700。任一失败 → throw 拒绝启动，绝不在宽松权限下返回私钥。新建仍 0600 / 目录 0700（现状不变）。

- [x] **Step 1：写三态 fail-closed 失败测试**

改 `relay-dialout/Tests/RelayDialoutCoreTests/DevKeyStoreTests.swift`，追加：

```swift
/// #8：加载 0644（对其他本机用户可读）的已存在私钥——加载前收紧为 0600（本用例验证收紧成功路径）。
@Test func devKeyStoreTightensLoosePermissionsOnLoad() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s1 = try DevKeyStore(dir: dir)                   // 首次创建（0600）
    let idPub = s1.identityPublicKeyRaw
    let identityURL = dir.appendingPathComponent("identity.key")
    // 人为放宽为 0644，模拟迁移/恢复。
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: identityURL.path)

    let s2 = try DevKeyStore(dir: dir)                   // 再加载：应收紧且复用同一身份
    #expect(s2.identityPublicKeyRaw == idPub)
    let perms = (try FileManager.default.attributesOfItem(atPath: identityURL.path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(perms == 0o600)                              // 已收紧
}

/// #8：私钥路径是符号链接 → fail-closed 抛错，不经软链读目标文件。
@Test func devKeyStoreRejectsSymlink() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    // 目标文件放到 dir 外；identity.key 是指向它的软链。
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".key")
    try Curve25519.Signing.PrivateKey().rawRepresentation.write(to: target)
    defer { try? FileManager.default.removeItem(at: target) }
    let identityURL = dir.appendingPathComponent("identity.key")
    try FileManager.default.createSymbolicLink(at: identityURL, withDestinationURL: target)

    #expect(throws: (any Error).self) { _ = try DevKeyStore(dir: dir) }
}
```

> 属主不符 Scenario：普通测试进程无法 `chown` 到别的 uid，无法构造「属主 != 当前 uid」的真文件而不提权。以**代码走查 + 符号链接/0644 两个可自动化用例**覆盖该分支，属主校验逻辑随 Step 3 实现并在 verify 阶段的本地清单做真机/手动确认（记入 Task 9.4）。

- [x] **Step 2：跑测试确认失败**

Run: `swift test --package-path relay-dialout --filter DevKeyStore`
Expected: `devKeyStoreRejectsSymlink` FAIL（现实现直接 `Data(contentsOf:)` 跟随软链读成功、不抛）；`devKeyStoreTightensLoosePermissionsOnLoad` FAIL（现实现读已存在文件不 chmod，perms 仍 0644）。

- [x] **Step 3：`loadOrCreateIdentity` 加 fail-closed 校验**

改 `relay-dialout/Sources/RelayDialoutCore/DevKeyStore.swift`。错误枚举（:16-19）加一个 case：
```swift
    public enum DevKeyStoreError: Error, Equatable {
        case unreadableKeyFile(String)
        case corruptedKeyFile(String)
        case insecureKeyFile(String)   // #8：符号链接 / 属主不符 / 权限收紧失败
    }
```
`init`（:27-40）在读身份前已确保目录存在；补一步把父目录收紧 0700（已存在目录也收紧）：
```swift
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            // #8：已存在目录亦收紧到 0700（迁移/恢复可能放宽）。
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
```
`loadOrCreateIdentity`（:42-56）在读已存在文件前插入校验：
```swift
    private static func loadOrCreateIdentity(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // #8 fail-closed：读前校验安全属性，任一失败即抛（绝不在宽松权限下用私钥）。
            try validateAndTightenExisting(at: url)
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw DevKeyStoreError.unreadableKeyFile(url.path) }
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw DevKeyStoreError.corruptedKeyFile(url.path)
            }
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try writeSecret(key.rawRepresentation, to: url)
        return key
    }

    /// #8：拒绝符号链接、校验属主==当前 uid、收紧文件权限到 0600。任一失败抛 insecureKeyFile。
    private static func validateAndTightenExisting(at url: URL) throws {
        var st = stat()
        // lstat 不跟随软链：先判符号链接。
        guard lstat(url.path, &st) == 0 else { throw DevKeyStoreError.insecureKeyFile(url.path) }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw DevKeyStoreError.insecureKeyFile(url.path) }
        // 属主必须是当前用户。
        guard st.st_uid == getuid() else { throw DevKeyStoreError.insecureKeyFile(url.path) }
        // 收紧到 0600。
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { throw DevKeyStoreError.insecureKeyFile(url.path) }
    }
```
`writeSecret`（:59-62）保持 0600 不变。

- [x] **Step 4：跑测试确认通过 + 既有不回归**

Run: `swift test --package-path relay-dialout --filter DevKeyStore`
Expected: 新两用例 PASS；既有 `devKeyStorePersistsAndReloads` / `...0600Permissions` / `...CorruptedKeyFile` / `...UnreadableKeyFile` 全绿（注意 `...UnreadableKeyFile` 用 0o000：`validateAndTightenExisting` 的属主校验先过、chmod 到 0600 成功，随后 `Data(contentsOf:)` 仍可读——该用例原意是「不可读即抛」，0o000 chmod 后变可读会改变其语义。**执行者须核对**：若收紧后该用例读到内容不再抛，改用「目录不可读」或「删读权限后 lstat 属主校验」保持其 fail-closed 断言；优先保留既有用例的不变量，必要时同步微调其构造）。

- [x] **Step 5：勾选并提交**

勾选 tasks.md 4.1/4.2/4.3。
```bash
git add relay-dialout/Sources/RelayDialoutCore/DevKeyStore.swift \
  relay-dialout/Tests/RelayDialoutCoreTests/DevKeyStoreTests.swift openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#8): validate & tighten existing dev key file perms before load (fail-closed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5（#3）：空闲会话按需调度攒批（能耗）

**对应 tasks.md：** 5.1 / 5.2 / 5.3 ｜ **验收 spec：** `specs/ipad-energy-lifecycle/spec.md` Requirement「iPad 空闲流式攒批按需调度不空转」（3 个 Scenario：空闲零周期唤醒 / 活跃约 30Hz / 停止观察兜底不丢尾字）

**Files:**
- Modify: `ios/CodexRemote/Stores/ConversationStore.swift:20,41-56,58-64,70-88`（去常驻循环，改按需调度）
- Test: `ios/CodexRemoteTests/ConversationCoalesceSchedulingTests.swift`（新增）

**Interfaces:**
- Consumes：`ThreadReducer.coalescer`（`StreamCoalescer`，有 `var isEmpty: Bool` 与 `func drain()`，见 `Domain/ThreadReducer.swift:12-52`）；`reducer.apply(_:to:)`（会把 delta `append` 进 coalescer）。
- Produces：`ConversationStore` 私有 `flushTask: Task<Void, Never>?` 替代 `coalesceTask`；私有 `func scheduleFlushIfNeeded()`；`flushCoalesced()` 与 `stopObserving()` 语义保持（`stopObserving` 仍强制最后一次 flush）。

**锁定决策（来自 Design Doc §五，按需调度）：** 去掉常驻 `while` 循环。脏 delta 入队且当前无 pending flush → 安排一次延迟 flush（33ms）。`flushCoalesced` drain 后**不自动续期**，下批脏数据到达再调度。`stopObserving` 仍强制最后一次 flush 兜底（不丢尾字）。空闲时对主线程零唤醒。

- [x] **Step 1：写按需调度测试**

新建 `ios/CodexRemoteTests/ConversationCoalesceSchedulingTests.swift`。ConversationStore 需要 `JSONRPCClient`（用现成 `MockTransport`）；通过 `startObserving()` 起观察，`MockTransport.feed` 推 delta 通知，断言 state 在 ~33ms 内合并落地、且空闲后不再变化：

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ConversationCoalesceSchedulingTests: XCTestCase {

    private func makeStore() async -> (ConversationStore, MockTransport) {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t")
        await store.startObserving()
        return (store, mock)
    }

    /// 活跃：连续 delta 到达后，攒批在一个调度周期内合并落地（逐字一致）。
    func test_active_deltas_flush_within_one_cycle() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        for d in ["Hel", "lo, ", "世界"] {
            await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"\#(d)"}}"#)
        }
        // 等待一次 33ms 调度周期 + 余量。
        try await Task.sleep(nanoseconds: 120_000_000)
        guard case .agentMessage(_, let text)? = store.state.items.first(where: { $0.id == "a1" }) else {
            return XCTFail("应有 a1")
        }
        XCTAssertEqual(text, "Hello, 世界")   // 逐字一致，不丢帧
    }

    /// 空闲：flush 完成后不再有周期性变化——快照两次相等即证明无常驻循环重复发布。
    func test_idle_no_periodic_wakeups() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"X"}}"#)
        try await Task.sleep(nanoseconds: 120_000_000)   // 落地
        let snap1 = store.state.items
        try await Task.sleep(nanoseconds: 300_000_000)   // 空闲窗口
        let snap2 = store.state.items
        XCTAssertEqual(snap1.count, snap2.count)
        guard case .agentMessage(_, let t1)? = snap1.first, case .agentMessage(_, let t2)? = snap2.first
        else { return XCTFail("应有 a1") }
        XCTAssertEqual(t1, t2)   // 空闲期间无变化（无周期性 drain 覆盖）
    }

    /// 停止观察：仍有未 flush 的攒批内容时 stopObserving 强制最后一次 flush，尾字不丢。
    func test_stopObserving_flushes_tail() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"TAIL"}}"#)
        // 不等待调度周期，立即停止：兜底 flush 必须把 TAIL 落地。
        store.stopObserving()
        guard case .agentMessage(_, let text)? = store.state.items.first(where: { $0.id == "a1" }) else {
            return XCTFail("应有 a1")
        }
        XCTAssertEqual(text, "TAIL")
    }
}
```

> 说明：delta 通知的 method/params 形状照 `StreamCoalescerTests` 里 `notif("item/agentMessage/delta", ["itemId":..., "delta":...])` 的既有约定。若 `belongsToThread` 过滤要求 params 带 `threadId`，delta 缺省全收（`ConversationStore.belongsToThread` :186-190：无 threadId 返回 true），故上面帧不带 threadId 即可被消费。

- [x] **Step 2：跑测试确认失败/或暴露常驻循环行为**

Run: `-only-testing:CodexRemoteTests/ConversationCoalesceSchedulingTests`
Expected: `test_stopObserving_flushes_tail` 应已通过（现实现 stopObserving 已 flush）；`test_active_...` 现实现也可能通过（常驻 30Hz 循环恰好覆盖）——关键回归锚是重构后三者**同时**保持绿。先记录基线，再重构。

- [x] **Step 3：改为按需调度**

改 `ios/CodexRemote/Stores/ConversationStore.swift`。字段（:20-21）改名：
```swift
    /// #3：按需一次性延迟 flush 任务（非常驻循环）。有 pending 时不重复安排。
    private var flushTask: Task<Void, Never>?
```
`startObserving()`（:41-56）删掉 `startCoalesceTimer()` 调用（:44），并在每次 apply 后按需调度：
```swift
        observer = Task { [weak self] in
            for await n in stream {
                await MainActor.run {
                    guard let self else { return }
                    guard self.belongsToThread(n) else { return }
                    self.reducer.apply(n, to: &self.state)
                    self.drainQueueIfTurnEnded(n)
                    self.scheduleFlushIfNeeded()   // #3：有脏 delta 才安排一次延迟 flush
                }
            }
        }
```
`stopObserving()`（:58-64）改用 `flushTask`：
```swift
    func stopObserving() {
        observer?.cancel()
        observer = nil
        flushTask?.cancel()
        flushTask = nil
        flushCoalesced()   // #3：兜底最后一次 flush，尾字不丢。
    }
```
删除 `startCoalesceTimer()`（:70-79），换成按需调度器：
```swift
    // MARK: - #3：流式攒批按需调度（约 30Hz，空闲零唤醒）

    /// 有脏 delta 且当前无 pending flush 时，安排一次 33ms 后的 flush。drain 后不续期。
    private func scheduleFlushIfNeeded() {
        guard flushTask == nil, !reducer.coalescer.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil        // 先清 pending 标志，再 drain：下批脏数据可重新调度
            self.flushCoalesced()
        }
    }
```
`flushCoalesced()`（:82-88）**不动**（drain + 一次发布；无脏项不发布）。

> 不变量：空闲（无 delta）→ `scheduleFlushIfNeeded` 因 `coalescer.isEmpty` 早退，`flushTask` 保持 nil，主线程零唤醒。活跃流→首个 delta 安排一次 33ms flush；期间到达的 delta 因 `flushTask != nil` 不重复安排，33ms 到点一次合并（约 30Hz）；drain 后清 flushTask，下批再调度。

- [x] **Step 4：跑测试确认三者全绿**

Run: `-only-testing:CodexRemoteTests/ConversationCoalesceSchedulingTests` + `-only-testing:CodexRemoteTests/StreamCoalescerTests`
Expected: 新三用例全绿；既有 `StreamCoalescerTests`（逐字一致/多 id/fallback 陷阱）不回归。

- [x] **Step 5：勾选并提交**

勾选 tasks.md 5.1/5.2/5.3。
```bash
git add ios/CodexRemote/Stores/ConversationStore.swift ios/CodexRemoteTests/ConversationCoalesceSchedulingTests.swift \
  openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#3): coalesce flush on-demand instead of 30Hz resident timer (idle zero-wakeup)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6（#4）：扫码相机启停串行化（能耗/隐私）

**对应 tasks.md：** 6.1 / 6.2 / 6.3 ｜ **验收 spec：** `specs/relay-qr-pairing/spec.md`（2 个 Scenario：关闭扫码页后相机不残留运行 / 快速开关不产生竞态残留）

**Files:**
- Modify: `ios/CodexRemote/Views/QRScannerView.swift:32-83`（串行队列 + `desiredRunning` 目标态）
- Test: `ios/CodexRemoteTests/QRScannerLifecycleTests.swift`（新增，测目标态对齐状态机逻辑）

**Interfaces:**
- Produces：`PreviewView` 私有 `let captureQueue = DispatchQueue(label: "qr.capture.serial")`（串行）；私有 `var desiredRunning = false`（仅在 `captureQueue` 上读写）；`func start()` / `func stop()` 只设目标态并排「对齐」任务。为可测，抽出纯逻辑对齐函数 `static func reconcile(desired: Bool, isRunning: Bool) -> CameraAction`（enum `.start / .stop / .noop`）。

**锁定决策（来自 Design Doc §六）：** `start`/`stop` 只设 `desiredRunning` 并在**单一私有串行队列**排一个「对齐实际态到目标态」的任务；`stop` **无条件排队**（不因 `isRunning == false` 早退）。保证 dismantle 后的 stop 一定排在先前 start 之后 → 最终态收敛到「停止」。模拟器无相机 → 以对齐逻辑的**状态机单测** + 真机抽验。

- [x] **Step 1：写对齐状态机测试**

新建 `ios/CodexRemoteTests/QRScannerLifecycleTests.swift`。相机在模拟器不可用，故测**纯对齐决策**（不实际起相机）：

```swift
import XCTest
@testable import CodexRemote

final class QRScannerLifecycleTests: XCTestCase {
    /// 目标态 = 停止：无论当前是否在跑，最终决策要么停要么无操作，绝不 start。
    func test_reconcile_desired_stop_never_starts() {
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: false, isRunning: true), .stop)
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: false, isRunning: false), .noop)
    }
    /// 目标态 = 运行：未跑则启动，已跑则无操作（幂等）。
    func test_reconcile_desired_start() {
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: true, isRunning: false), .start)
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: true, isRunning: true), .noop)
    }
    /// 关键回归锚（dismantle 后 stop）：先 start 再 stop 的目标态序列，最终目标态=停止 → 决策绝不是 start。
    func test_start_then_stop_converges_to_stop() {
        // 模拟串行队列按序应用：start 设 desired=true，stop 设 desired=false（最后一次为准）。
        var desired = false
        desired = true                      // start()
        desired = false                     // stop()（无条件，不早退）
        XCTAssertNotEqual(QRScannerView.PreviewView.reconcile(desired: desired, isRunning: false), .start)
    }
}
```

- [x] **Step 2：跑测试确认失败**

Run: `-only-testing:CodexRemoteTests/QRScannerLifecycleTests`
Expected: 编译失败（`reconcile` / `CameraAction` 未定义）。

- [x] **Step 3：引入串行队列 + 目标态 + 对齐函数**

改 `ios/CodexRemote/Views/QRScannerView.swift`。`PreviewView`（:32-83）改造：

字段（:33-37 区域）加：
```swift
        // #4：单一私有串行队列 + 目标运行态，保证 start/stop 顺序对齐、最终态收敛。
        private let captureQueue = DispatchQueue(label: "com.codexremote.qr.capture")
        private var desiredRunning = false          // 仅在 captureQueue 上读写
        private var inputConfigured = false         // 首次对齐时懒配置 input/output
```
新增对齐决策类型与纯函数：
```swift
        enum CameraAction: Equatable { case start, stop, noop }

        /// 纯对齐决策（可单测）：目标态 vs 实际运行态 → 该做的动作。
        static func reconcile(desired: Bool, isRunning: Bool) -> CameraAction {
            switch (desired, isRunning) {
            case (true, false):  return .start
            case (false, true):  return .stop
            default:             return .noop
            }
        }
```
`start()`（:42-61）改为只设目标态 + 排对齐：
```swift
        func start() {
            captureQueue.async { [weak self] in self?.setDesired(true) }
        }
```
`stop()`（:63-67）**无条件排队**（删掉 `guard session.isRunning else { return }`）：
```swift
        func stop() {
            captureQueue.async { [weak self] in self?.setDesired(false) }
        }
```
新增在串行队列上执行的目标态设置 + 对齐（相机配置从 `start` 迁到首次对齐处）：
```swift
        /// 仅在 captureQueue 上执行：更新目标态并把实际态对齐过去。
        private func setDesired(_ running: Bool) {
            desiredRunning = running
            switch Self.reconcile(desired: desiredRunning, isRunning: session.isRunning) {
            case .start:
                configureInputsIfNeeded()
                guard session.inputs.isEmpty == false else { return }   // 相机不可用（模拟器）→ 不启
                session.startRunning()
            case .stop:
                session.stopRunning()
            case .noop:
                break
            }
        }

        /// 懒配置 input/output（仅一次）。相机不可用时静默返回，session.inputs 保持空。
        private func configureInputsIfNeeded() {
            guard !inputConfigured else { return }
            inputConfigured = true
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.previewLayer.session = self.session
                self.previewLayer.videoGravity = .resizeAspectFill
            }
        }
```
`metadataOutput`（:70-82）里的 `session.stopRunning()`（:79）改为经目标态收敛，避免与串行队列竞争：
```swift
            MainActor.assumeIsolated {
                guard !didScan else { return }
                didScan = true
                onScan?(s)
            }
            captureQueue.async { [weak self] in self?.setDesired(false) }   // 命中后停止（走同一串行路径）
```
删除原 `SessionBox`（:28-30）——不再需要跨并发边界（所有 session 触碰统一在 `captureQueue`）；`session` 的 `nonisolated(unsafe)` 保留（仍被 main 队列的 delegate 与 captureQueue 触碰，但写入已串行化到 captureQueue，delegate 只读+调度）。

> 关键不变量（Scenario 1）：dismantle 调 `stop()` → 排入 `setDesired(false)`；它一定排在任何先前 `start()` 排入的 `setDesired(true)` 之后（同一串行队列 FIFO）。故最终 `desiredRunning == false`，对齐结果为 `.stop` 或 `.noop`，相机不残留。

- [x] **Step 4：跑测试确认通过 + 编译**

Run: `-only-testing:CodexRemoteTests/QRScannerLifecycleTests` + 模拟器编译
Expected: 3 用例 PASS；`QRScannerView` 编译通过（模拟器无相机路径静默）。

- [x] **Step 5：真机抽验项记入本地清单**

在 verify 阶段本地清单记：真机打开扫码页→关闭→确认相机指示灯熄灭（无残留）；快速进出扫码页多次无卡死/无残留（Scenario 2）。记入 Task 9.4。

- [x] **Step 6：勾选并提交**

勾选 tasks.md 6.1/6.2/6.3。
```bash
git add ios/CodexRemote/Views/QRScannerView.swift ios/CodexRemoteTests/QRScannerLifecycleTests.swift \
  openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#4): serialize camera start/stop via serial queue + desiredRunning target state

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7（#6）：侧栏首拉后按可见性再轮询（能耗）

**对应 tasks.md：** 7.1 / 7.2 / 7.3 ｜ **验收 spec：** `specs/ipad-energy-lifecycle/spec.md` Requirement「iPad 列表轮询以可见性/前台为启动前置」（2 个 Scenario：后台/视图消失时首拉完成不重启轮询 / 前台可见时正常启动）

**Files:**
- Modify: `ios/CodexRemote/Views/SidebarView.swift:42-49`（`.task` 内 startPolling 前 guard）
- Modify: `ios/CodexRemote/Stores/ProjectsStore.swift:99-108`（`startPolling` 加可见性前置）
- Test: `ios/CodexRemoteTests/ProjectsPollingTests.swift`（追加）

**Interfaces:**
- Produces：`ProjectsStore.startPolling(intervalNanos:isVisible:)`——新增默认参数 `isVisible: Bool = true`，`guard isVisible else { return }` 前置（双重防护）。
- Consumes：`SidebarView` 已有 `@Environment(\.scenePhase) private var scenePhase`（:11）与 `Task.isCancelled`。

**锁定决策（来自 Design Doc §七）：** `.task` 内 `startPolling` 前加 `guard !Task.isCancelled && scenePhase == .active`；`ProjectsStore.startPolling` 自身加可见性前置，双重防护。

- [x] **Step 1：写「不可见时不启动轮询」测试**

改 `ios/CodexRemoteTests/ProjectsPollingTests.swift`，追加：

```swift
    /// #6：可见性前置——isVisible=false 时 startPolling 不启动（后台/视图消失场景）。
    func test_startPolling_skips_when_not_visible() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)

        s.startPolling(intervalNanos: 30_000_000, isVisible: false)   // 不可见 → 不应启动
        try await Task.sleep(nanoseconds: 120_000_000)
        let count = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertEqual(count, 0, "不可见时不应启动轮询")
    }

    /// 可见时正常启动（回归保护既有行为）。
    func test_startPolling_starts_when_visible() async throws {
        let s = ProjectsStore()
        let mock = MockTransport(); await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock); await rpc.start()
        await s.attach(rpc: rpc)
        s.startPolling(intervalNanos: 30_000_000, isVisible: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        s.stopPolling()
        let count = await mock.sent.filter { $0.contains("thread/list") }.count
        XCTAssertGreaterThanOrEqual(count, 1)
    }
```

- [x] **Step 2：跑测试确认失败**

Run: `-only-testing:CodexRemoteTests/ProjectsPollingTests`
Expected: 编译失败（`startPolling` 无 `isVisible:` 参数）。

- [x] **Step 3：`startPolling` 加可见性前置**

改 `ios/CodexRemote/Stores/ProjectsStore.swift:99`：
```swift
    func startPolling(intervalNanos: UInt64 = 4_000_000_000, isVisible: Bool = true) {
        guard isVisible else { return }             // #6：不可见/后台不启动（双重防护）
        guard pollTask == nil, let rpc else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { break }
                await self?.loadFromServer(rpc: rpc)
            }
        }
    }
```
既有默认参数 `isVisible: Bool = true` 保证 `.onChange(scenePhase == .active)`（SidebarView:55）与既有测试的无参调用不受影响。

- [x] **Step 4：`SidebarView.task` 首拉后按可见性/取消再轮询**

改 `ios/CodexRemote/Views/SidebarView.swift:42-49`：
```swift
        .task(id: connection.phase) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await projects.attach(rpc: rpc)
            await env.attach(rpc: rpc)
            await projects.loadFromServer(rpc: rpc)
            // #6：首拉是 await——期间可能切标签/视图消失/进后台。仅在仍可见且未取消时才启动轮询，
            // 否则会覆盖 onDisappear/scenePhase 的停止。
            guard !Task.isCancelled, scenePhase == .active else { return }
            projects.startPolling(isVisible: true)
        }
```
`.onChange(scenePhase)` 分支（:51-61）里的 `projects.startPolling()`（:55）保持无参（默认 `isVisible: true`，此分支已在 `.active` case 内，语义正确）。

- [x] **Step 5：跑测试确认通过 + 既有轮询测试不回归**

Run: `-only-testing:CodexRemoteTests/ProjectsPollingTests`
Expected: 新两用例 PASS；既有 `test_polling_refreshes_then_stops` / `test_startPolling_idempotent` 全绿（默认参数向后兼容）。

- [x] **Step 6：勾选并提交**

勾选 tasks.md 7.1/7.2/7.3。
```bash
git add ios/CodexRemote/Views/SidebarView.swift ios/CodexRemote/Stores/ProjectsStore.swift \
  ios/CodexRemoteTests/ProjectsPollingTests.swift openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#6): gate sidebar polling start on visibility/foreground (both call site and store)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8（#7）：后台暂停在途首连（能耗）

**对应 tasks.md：** 8.1 / 8.2 / 8.3 ｜ **验收 spec：** `specs/relay-e2e-transport/spec.md` Requirement「已升级连接的前后台能耗钩子覆盖在途首连」（3 个 Scenario：首连期间退后台不继续握手 / 回前台重试成功 / 取消不泄漏 transport）

**Files:**
- Modify: `ios/CodexRemote/Stores/ConnectionStore.swift:257-261`（`setForeground` 覆盖 inFlightTransport）、`:270-317`（`doEstablish` 前台检查）
- Test: `ios/CodexRemoteTests/ConnectionStoreTests.swift`（追加）

**Interfaces:**
- Consumes：既有 `inFlightTransport`（:97）、`activeAttempt` token（:105）、take-and-nil 关闭路径（`disconnect` :248 / 超时 :229-231 / `doEstablish` catch :311-314）、`MessageTransport.setForeground(_:)`（transport 层能耗钩子）、`#if DEBUG inFlightTransportForTesting`（:114）。
- Produces：`setForeground` 退后台时对在途首连执行「attempt-token 作废 + take-and-nil close inFlightTransport」；`foregroundActive` 状态供 `doEstablish` 建通道/握手前检查。

**锁定决策（来自 Design Doc §八）：** `setForeground` 同步状态给 `inFlightTransport`（不止已落地 transport）；`doEstablish` 建通道与初始握手前检查/等待前台；退后台时进行中首连走**既有** attempt-token 作废 + take-and-nil 关闭路径取消，回前台重试；take-and-nil 保 exactly-once 关闭，不泄漏 transport。

- [x] **Step 1：写「首连期间退后台取消在途 transport」测试**

改 `ios/CodexRemoteTests/ConnectionStoreTests.swift`，复用 `MockTransport.setBlockHandshake(true)`（握手永不完成，模拟在途首连挂起）+ `closeCount` / `inFlightTransportForTesting` 断言：

```swift
    /// #7：首连握手在途时退后台 → 在途 transport 被取消（close 恰好一次）、inFlight 清空、phase 非 .ready。
    func testBackgroundDuringInFlightConnectCancelsTransport() async throws {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)               // 握手永不完成 → doEstablish 挂在 awaitHandshake
        // 用较长超时排除超时兜底干扰：本用例要证明取消来自退后台而非超时。
        let store = await ConnectionStore(transportFactory: { _ in mock },
                                          connectTimeoutNanos: 20_000_000_000)
        await store.connect(config: .stub)
        // 等 inFlightTransport 就位（doEstablish 已设 inFlightTransport 后挂起）。
        try await waitUntil { await store.inFlightTransportForTesting != nil }

        await store.setForeground(false)                 // 退后台：应取消在途首连

        try await waitUntil { await mock.closeCount >= 1 }
        let count = await mock.closeCount
        XCTAssertEqual(count, 1, "退后台应关闭在途 transport 恰好一次，实际 \(count)")
        let inflight = await store.inFlightTransportForTesting
        XCTAssertNil(inflight, "退后台取消后应清空 inFlightTransport，不泄漏")
        if case .ready = await store.phase { XCTFail("在途首连被后台取消，不应到达 .ready") }
    }
```

> 「回前台重试成功」Scenario 由既有 `testHandshakeReachesReady` 的连接路径覆盖（回前台后重新 `connect()` 走正常握手到 `.ready`）；本 change 不改该正常路径，故不重复写整链集成，用一条断言在上面用例后追加「回前台再 connect 能 ready」即可（可选，见 Step 4 备注）。

- [x] **Step 2：跑测试确认失败**

Run: `-only-testing:CodexRemoteTests/ConnectionStoreTests/testBackgroundDuringInFlightConnectCancelsTransport`
Expected: FAIL —— 现 `setForeground`（:257-261）只 `guard let transport`（已落地），忽略 `inFlightTransport`，故退后台不关闭在途 transport，`closeCount` 停在 0、`inFlight` 仍非 nil。

- [x] **Step 3：`setForeground` 覆盖在途首连**

改 `ios/CodexRemote/Stores/ConnectionStore.swift:257-261`：
```swift
    func setForeground(_ active: Bool) {
        foregroundActive = active
        // 已落地 transport：转发状态（RelayTransport 后台暂停重连）。
        if let transport { Task { await transport.setForeground(active) } }
        // #7：在途首连（尚未落地的 inFlightTransport）也要覆盖——退后台时取消它，避免最长烧到 20s 超时。
        // 走既有 attempt-token 作废 + take-and-nil 关闭路径（与 disconnect / 超时兜底一致，exactly-once）。
        if !active, let inflight = inFlightTransport {
            inFlightTransport = nil          // take-and-nil：原子取所有权，防与 doEstablish catch 双关
            activeAttempt += 1               // 作废本次 attempt：其 establish 完成时 token 不匹配 → 忽略
            Task { await inflight.close() }  // close() → awaitHandshake 抛出 → doEstablish 解挂并 fail-closed
        }
    }
```

> 说明：`activeAttempt += 1` 使正在 `doEstablish` 的任务即便随后解挂，也因 `attempt != self.activeAttempt`（connect :184-190 / :205）而不落地、并在 catch 里因 `inFlightTransport` 已被取走（identity 不匹配）不重复 close——与既有超时兜底/新连接作废路径语义一致，保 exactly-once。

- [x] **Step 4：`doEstablish` 建通道/握手前检查前台（可选加固）**

Design Doc §八要求「`doEstablish` 建通道与初始握手前检查/等待前台」。最小实现：在 `doEstablish`（:270-283）建 transport 前与 `awaitHandshake` 前各加一处前台快照检查，退后台则提前 fail-closed（不烧握手）：
```swift
    private func doEstablish(_ config: ConnectionConfig) async throws -> (JSONRPCClient, MessageTransport) {
        phase = .connecting
        guard foregroundActive else { throw TransportError.notConnected }   // #7：后台不发起首连
        ...
        // awaitHandshake 前再检查一次（异步窗口内可能已退后台；退后台路径已作废 attempt 并关 transport）。
        ...
```

> 注意：主取消路径是 Step 3 的 close()（令 `awaitHandshake` 抛出）。此处前台检查是纵深防御；若引入首连回归（正常路径 `foregroundActive` 恒为 true，默认前台），保持它不影响 `testHandshakeReachesReady`。执行者若发现该检查导致既有连接测试 flaky，可退化为仅保留 Step 3 的取消路径（那已满足 3 个 Scenario 的核心断言），并在 verify 记录取舍。

（可选）在 Step 1 用例末尾追加回前台重试断言：
```swift
        // 回前台重试：重新 connect 应能正常到达 .ready（正常握手路径未被本 change 改变）。
        await mock.setBlockHandshake(false)
        await store.setForeground(true)
        // 后台喂 initialize 响应，略——与 testHandshakeReachesReady 同构；或直接断言可再次发起 connect 不悬挂。
```

- [x] **Step 5：跑全量 ConnectionStore 测试确认无回归**

Run: `-only-testing:CodexRemoteTests/ConnectionStoreTests`
Expected: 新用例 PASS；既有 `testHandshakeReachesReady` / `testConnectTimeoutClosesInFlightTransport` / `testInitializeFailureClosesTransportAndClearsInFlight` / `testDisconnectClosesTransport` / `testReconnecting...` 全部不回归（take-and-nil 竞态锚）。iOS **全量**测试跑一遍捕获跨 store 竞态（memory：全测曾捕获双关竞态）。

- [x] **Step 6：勾选并提交**

勾选 tasks.md 8.1/8.2/8.3。
```bash
git add ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemoteTests/ConnectionStoreTests.swift \
  openspec/changes/review-fixes-security-energy/tasks.md
git commit -m "fix(#7): background pause cancels in-flight first connect (attempt-token + take-and-nil)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9：收口验证

**对应 tasks.md：** 9.1 / 9.2 / 9.3 / 9.4 ｜ 全部 8 组完成后统一收口。

- [x] **Step 1：四个 Swift Package 测试全绿**

Run:
```bash
swift test --package-path relay-dialout
swift test --package-path relay-server
swift test --package-path packages/RelayProtocol
```
（RelayDialoutCore 测试含在 relay-dialout package 内。）
Expected: 全绿。#2 命中 `RelayDialoutCoreTests` 的 DialoutContextTrust；#8 命中 DevKeyStore。

- [x] **Step 2：iPad 模拟器全量测试全绿**

Run: `xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad Pro (11-inch)'`（destination 按本机可用模拟器调整）。
Expected: 全量绿。重点覆盖 #1 ClipboardPolicy、#3 ConversationCoalesceScheduling、#4 QRScannerLifecycle、#5 RelayE2EKeyManager、#6 ProjectsPolling、#7 ConnectionStore。

- [x] **Step 3：`xcodebuild analyze` 通过**

Run: `xcodebuild analyze -scheme CodexRemote -destination '...'`
Expected: 无新增静态分析告警。

- [x] **Step 4：能耗结论静态分析 + 真机验收项写入本地清单**

在 `docs/真机验收清单.md`（BACKLOG 指向的本地清单）追加本 change 的真机验收项：
- #1：设置页「隐私」开关默认关；关闭时远端 `printf '\e]52;c;<base64>\a'` 不改剪贴板；开启且小内容能写；开启且 >64KB 拒写。
- #4：真机打开/关闭扫码页，相机指示灯正确熄灭，无残留；快速进出多次无卡死。
- #7：真机首连握手途中切后台→再回前台，连接不空耗、能正常重连；#8：真机把 `~/.codex/...identity.key` 手动 `chmod 644` 后重启 dev，确认被收紧回 600；`chown` 到别的用户后确认 fail-closed 拒绝启动（属主校验的真机确认，补足 Task 4 单测无法覆盖的属主分支）。
- 能耗静态结论：#3 空闲无常驻定时器（代码走查 + `test_idle_no_periodic_wakeups`）；#6 后台/不可见不轮询；#7 在途首连后台即取消不烧 20s。

- [x] **Step 5：勾选 tasks.md 9.1–9.4 并提交收口**

```bash
git add openspec/changes/review-fixes-security-energy/tasks.md docs/真机验收清单.md
git commit -m "chore: verification pass for review-fixes-security-energy (4 pkg + iOS + analyze green)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 自查（Self-Review）

**1. Spec 覆盖：**
- `ipad-bottom-terminal`（#1，4 Scenario）→ Task 1（默认关 / 开且限内 / 开且超限 / 读方向 nil 全覆盖）。✅
- `relay-e2e-transport`（4 Requirement）：dev 落盘后发布（#2）→ Task 2；iPad 密钥落盘后缓存（#5）→ Task 3；dev 加载校验权限（#8）→ Task 4；前后台钩子覆盖在途首连（#7）→ Task 8。✅
- `relay-qr-pairing`（#4，2 Scenario）→ Task 6（dismantle 后不残留 / 快速开关无残留）。✅
- `ipad-energy-lifecycle`（2 Requirement）：空闲攒批按需（#3）→ Task 5；轮询可见性前置（#6）→ Task 7。✅

**2. Placeholder 扫描：** 无「TBD/实现细节从略/类似 Task N」。#8 属主分支与 #7 前台检查两处「执行者按环境择一/可退化」均给出了具体判据与替代构造，非占位。真机项明确落到本地清单。✅

**3. 类型一致性：**
- `ClipboardPolicyStore`：`allowRemoteWrite` / `shouldWrite(byteCount:)` / `maxWriteBytes` 在 Task 1 各步一致。✅
- `KeyStoring.saveKeyThrowing(_:)`（带默认实现）+ `RelayE2EKeyManager.identityKey() throws`：Task 3 定义与 `LiveTransport` 调用点 `try` 一致；SSH `KeyManager`/`KeychainKeyStore` 明确不动。✅
- `DevKeyStoreError.insecureKeyFile` + `reconcile`/`CameraAction` + `startPolling(isVisible:)` + `flushTask`/`scheduleFlushIfNeeded` 命名前后一致。✅
- #2/#7 复用既有 `TrustStore.trust`、`activeAttempt`、take-and-nil、`inFlightTransportForTesting`，签名与现源码一致。✅

**执行顺序建议：** 安全优先（Task 1→2→3→4），再能耗（5→6→7→8），末 Task 9 收口。8 组互不依赖，可并行分派，但每组独立提交、独立跑该组测试后再进下一组。
