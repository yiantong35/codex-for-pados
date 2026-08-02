---
comet_change: remove-ssh-transport
role: technical-design
canonical_spec: openspec
---

# Design Doc — remove-ssh-transport

- **Date**: 2026-08-02
- **Change**: `openspec/changes/remove-ssh-transport`
- **Workflow**: comet full · design phase
- **Isolation**: worktree, base_ref `8b778a40`
- **Merge order**: 谁先好谁先合（与 change A `connection-health-visibility` 并行；后者解冲突）

## 目标

移除 SSH 传输层全栈，relay 成为唯一连接路径。app 未上线，不做存量迁移兼容——当新 app 做，怎么干净怎么来。

## 前置：对抗性安全审查结论（open 阶段，5 verifier）

- **安全姿态 sound**：relay 鉴权/TOFU/E2E 独立于 SSH；无 fail-open（删 SSH 后无更弱/明文可退）；Keychain account/service 隔离 + scoped delete，删 SSH 私钥不误删 relay。
- **2 个 BLOCKER（删除计划缺陷，非安全洞）**：见下 §1、§4。

## 实现顺序（关键：BLOCKER 前置）

```
0. 解耦 KeyStoring（新文件）          ← 必须最先，否则删 KeyManager 破坏 relay 编译
1. 删 SSH 传输内核（4 文件）
2. 清理 Keychain SSH 私钥 + 删 SSH 安全模块（2 文件）
3. 收敛机器模型 MachineConfig/MachineStore（含 ConnectionKind 内联）
4. 收敛连接分派 ConnectionStore/LiveTransport
5. 收敛 UI MachineFormView + 删 ConnectionConfigView
6. 清理测试
7. 验证（编译 gate + relay 冒烟 + 安全回归）
```

## §0. KeyStoring 解耦（BLOCKER 前置）

**问题**：`protocol KeyStoring` + `saveKeyThrowing` throwing 默认**仅**定义在 `KeyManager.swift:7-18`；KEPT 的 relay `RelayE2EKeychainStore: KeyStoring`（`RelayE2EKeyManager.swift:7`）依赖它。直接删 `KeyManager.swift` → relay 编译失败；若迁移丢 throw 语义 → relay 身份落盘 fail-open。

**方案**：
1. 新建 `ios/CodexRemote/Security/KeyStoring.swift`，剪切 `protocol KeyStoring { saveKey / saveKeyThrowing / loadKey / deleteKey }` + `extension KeyStoring { saveKeyThrowing 默认转调 saveKey }` 过去。
2. `RelayE2EKeyManager` / `RelayE2EKeychainStore` **一行不改**（同 target internal 可见），`RelayE2EKeychainStore.saveKeyThrowing` 的 override（真抛写失败）原样保留。
3. 新增/保留单测：断言 `RelayE2EKeychainStore.saveKeyThrowing` 在底层写失败时**仍 throw**——锁死 relay 身份落盘 fail-closed，防未来回归。
4. pbxproj 加入 `KeyStoring.swift`。

**接口契约**：`KeyStoring` 语义完全不变，仅换文件。消费者（relay）编译单元只依赖 survive 文件。

## §1. 删 SSH 传输内核

删除（真闭合子图，relay 零依赖，审查 CONFIRMED）：
- `Transport/SSHClient.swift`（内含 `SSHClientWrapper`、`SSHHostKeyStoring` 消费）
- `Transport/ProxyChannel.swift`
- `Transport/WSFrame.swift`（仅 ProxyChannel 用）
- `Transport/DaemonBootstrap.swift`（零引用死代码）

pbxproj 同步移除引用。

## §2. Keychain 清理 + 删 SSH 安全模块

**Keychain 清理**（决策 2）：
- `CodexRemoteApp` 启动路径加极小 migration hook：`KeychainStore().delete("ssh-ed25519-private-key")`（service `com.codexremote.ssh`）。
- 幂等无 flag：`errSecItemNotFound` = 已清理成功；其它错误记日志不阻断启动（清理失败不比保留现状更差，故不 fail-closed 阻断）。
- account+service 精确 scoped，审查已证不误删 relay 密钥。

**删安全模块**（§0 完成后）：
- `Security/KeyManager.swift`（`KeyStoring` 已迁出）
- `Transport/SSHHostKeyStore.swift`（含 `SSHHostKeyStoring` 协议 + `KeychainSSHHostKeyStore`；唯一消费者 `SSHClient` 已删）

## §3. 收敛机器模型（MachineConfig / MachineStore）

**MachineConfig**（决策 3：删 enum 内联）：
- 删 `ConnectionKind` enum；`relayURL` / `sessionId` / `devIdentityPubB64` 内联为 `MachineConfig` 直接属性。
- 删 SSH 便利 init、designated init 的 `if case .ssh`（:76）、legacy flat-format→`.ssh` 解码迁移、SSH 兼容 shim（`host`/`user`/`sshPort`/`sockPath`、`static sockPath(forUser:)`）。
- `var connectionConfig`（:146-155）只产 relay `ConnectionConfig`。
- 所有 `case .relay(...)` 构造/匹配点（`RelayPairingImportView.swift:57-59` 等）改为直接字段访问。

**MachineStore**（BLOCKER：all-or-nothing decode）：
- 删 `migrateLegacyIfNeeded()`（:85）的 `.ssh` minting（否则引用已删 case 不编译）。
- decode（:65）保持现状：app 未上线无 `.ssh` 持久化数据 → 无损；不新增迁移代码（履行"当新 app"定调）；开发期模拟器脏 `.ssh` 数据视为一次性丢弃。

## §4. 收敛连接分派（ConnectionStore / LiveTransport / TransportError）

- `App/LiveTransport.swift`：`liveTransportFactory` 删 SSH else 分支（`makeSharedDaemonTransport`、`KeyManager().privateKey()` @:89,92）；relay `.relay` 分支保留（同文件）。nil-relay 结构性 throw（fail-closed）。
- `Stores/ConnectionStore.swift`：删 SSH 分派分支 + `KeyManager().hasKey`（:158）；`ConnectionConfig` 删 SSH 字段（`host`/`user`/`sshPort`/`controlSockPath`），`isRelay` 塌缩（恒真）；gating 只校验 relay 载荷非空。
- `Transport/TransportError.swift`：删 `.sshAuthFailed`/`.proxyFailed`。

## §5. 收敛 UI

- `Views/MachineFormView.swift`：删 host/user/port/sock 输入项 + `KeyManager()`（:20）+ `generateIfNeeded()` + `.ssh` MachineConfig 构造（:205-211）；仅留 relay 配对导入路径。
- 删 `Views/ConnectionConfigView.swift`（全屏 SSH 连接配置页，含 `KeyManager`/`generateIfNeeded`）+ 检查调用点改走 relay 表单。
- pbxproj 移除 `ConnectionConfigView.swift`。

## §6. 清理测试

- 删 SSH-only 测试文件：`SSHHostKeyStoreTests`、`KeyManager` 相关测试。
- 清理 ~18 个测试文件的 SSH 断言/构造（`ConnectionStoreTests` / `MachineConfigTests` / `MachineFormViewTests` / `MachineStoreTests` / `KeychainStoreTests` 等）。
- relay 测试（`RelayE2EKeyManagerTests` / `RelayFactoryTests` / `RelayHandshakeTests` / `TOFUStoreTests` 等）不动；新增 §0 的 `saveKeyThrowing` throw 断言。

## §7. 验证策略

- **编译 gate**：全量编译通过（编译器 100% 抓残留 `KeyManager()`/`.ssh`/SSH 符号引用）；grep 二次确认零 `SSHClient`/`ProxyChannel`/`sshPort`/`SSHHostKey` 生产符号。
- **测试 gate**：全量测试通过，`xcresulttool` 权威计数；relay 测试全绿 + `saveKeyThrowing` throw 断言绿。
- **relay 冒烟**：模拟器经 relay 配对导入建连、收发正常。
- **安全回归**：确认无 fail-open 回退（nil-relay throw）；Keychain SSH 私钥已清理；relay 身份落盘写失败仍 throw。

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 删 KeyManager 破坏 relay 编译（BLOCKER） | §0 先迁 KeyStoring，排删除之前 |
| KeyStoring 迁移丢 throw → relay 身份 fail-open | 保留 override + 断言单测锁死 |
| MachineStore 整数组 nil 丢 relay 机器（BLOCKER） | 删 `.ssh` minting；app 未上线无存量数据 |
| 遗漏 SSH 引用点 | 编译器 hard error 兜底 + grep 二次确认 |
| pbxproj 手改 dangling 引用 | 删后立即编译验证 |
| 与 change A 撞 ConnectionStore | worktree 隔离；B 改（删 SSH 字段）与 A 改（加健康态）语义正交，机械可解 |

## 非目标

- 不做存量迁移兼容；不动 relay E2E 栈实现；不改协议/daemon/dialout；不动 change A 的健康可视化。
