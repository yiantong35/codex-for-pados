import Foundation

/// SSH host key TOFU 校验失败：
/// - `hostKeyChanged`：服务器出示的 host key 与首次记住的不一致（可能中间人或服务器身份变更）。
/// - `recordCorrupted`：Keychain 里存在记录但内容损坏（非法 base64），无法还原信任锚；
///   fail-closed 拒连而非静默当"无记录"覆盖——须用户显式重置信任。
enum SSHHostKeyError: Error, Equatable { case hostKeyChanged; case recordCorrupted }

/// iPad 侧 SSH host key TOFU 存储抽象：按机器稳定键记开发机 SSH host key。
///
/// 独立于 relay 侧 TOFU（`TOFUStoring`，account `relay-tofu-*`）与 E2E 开发机身份密钥，
/// 互不复用同一 Keychain 记录——SSH 链路身份与 relay E2E 身份是两条独立信任锚。
protocol SSHHostKeyStoring: Sendable {
    /// 取该机器键已记住的 SSH host key 序列化字节。
    /// 仅"确实无记录"（Keychain `errSecItemNotFound`）返回 nil；
    /// 读取遇 notFound 以外的任何错误（锁屏窗口期 `errSecInteractionNotAllowed`、
    /// `errSecAuthFailed`、瞬时故障等）必须上抛（fail-closed）——绝不把读失败静默当首信。
    /// 记录存在但内容损坏（非法 base64）抛 `SSHHostKeyError.recordCorrupted`——绝不当"无记录"
    /// 覆盖信任锚，须用户显式重置信任。
    func rememberedHostKey(forMachineKey key: String) throws -> Data?
    /// 记住该机器键的 SSH host key（覆盖式）。持久化失败必须上抛（fail-closed）。
    func remember(_ hostKey: Data, forMachineKey key: String) throws
}

extension SSHHostKeyStoring {
    /// 首次即信任存下；再连比对，不匹配抛 `hostKeyChanged`（fail-closed）。
    /// 首信持久化失败会上抛底层错误——信任锚未落盘绝不放行连接，
    /// 否则下次又当"首信"会重新信任服务器出示的任意 host key，MITM 检测静默失效。
    ///
    /// 读取信任锚失败同样上抛（`try rememberedHostKey`）：只有明确"无记录（notFound）→ nil"
    /// 才走首信持久化；读到 notFound 以外错误则拒连，绝不覆盖已有信任锚、绝不当首信。
    func verifyOrTrust(machineKey: String, presentedHostKey: Data) throws {
        if let known = try rememberedHostKey(forMachineKey: machineKey) {
            guard known == presentedHostKey else { throw SSHHostKeyError.hostKeyChanged }
        } else {
            try remember(presentedHostKey, forMachineKey: machineKey)
        }
    }
}

/// Keychain 持久实现（防篡改：存储被改 = TOFU 失效；别的 app / 越狱环境动不了）。
/// service 默认 `com.codexremote.ssh-hostkey`，account 命名 `ssh-hostkey-<machineKey>`，一机器一记录。
/// 与 relay 的 `com.codexremote.relay-tofu` 及 E2E 密钥 service 天然隔离。
struct KeychainSSHHostKeyStore: SSHHostKeyStoring {
    let keychain: KeychainStore
    init(service: String = "com.codexremote.ssh-hostkey") {
        self.keychain = KeychainStore(service: service)
    }
    private func account(_ key: String) -> String { "ssh-hostkey-\(key)" }

    func rememberedHostKey(forMachineKey key: String) throws -> Data? {
        // `KeychainStore.load` 已区分：notFound → nil（确实无记录），其它 OSStatus → throw。
        // 这里不再用 `try?` 吞错——读失败会上抛，由 verifyOrTrust/delegate 传播为拒连（fail-closed）。
        guard let s = try keychain.load(account(key)) else { return nil }
        // 关严：字符串存在但非法 base64 → 抛"记录损坏"（不再返回 nil 当无记录 → 覆盖信任锚）。
        guard let data = Data(base64Encoded: s) else { throw SSHHostKeyError.recordCorrupted }
        return data
    }
    func remember(_ hostKey: Data, forMachineKey key: String) throws {
        try keychain.save(hostKey.base64EncodedString(), for: account(key))
    }
}
