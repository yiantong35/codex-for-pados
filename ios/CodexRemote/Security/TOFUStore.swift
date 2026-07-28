import Foundation

/// TOFU 校验失败：`identityChanged` = 开发机身份公钥与首次记住的不一致（可能中间人替换）；
/// `recordCorrupted` = 信任锚记录存在但内容损坏（非法 base64），必须 fail-closed 拒连、须显式重置信任。
enum TOFUError: Error, Equatable { case identityChanged; case recordCorrupted }

/// iPad 单边 TOFU 信任存储抽象：按机器稳定键记开发机身份公钥。
protocol TOFUStoring: Sendable {
    /// 取该机器键已记住的开发机身份公钥。
    /// `nil` 仅表「确实无记录」（Keychain `errSecItemNotFound`）；其它读错误 rethrow；
    /// 记录存在但内容损坏（非法 base64）抛 `TOFUError.recordCorrupted`（fail-closed，须显式重置信任）——
    /// 绝不把读失败/损坏静默当「从未信任」而覆盖信任锚。
    func rememberedIdentity(forMachineKey key: String) throws -> Data?
    /// 记住该机器键的开发机身份公钥（覆盖式）。持久化失败必须上抛（fail-closed）。
    func remember(_ identityPub: Data, forMachineKey key: String) throws
}

extension TOFUStoring {
    /// 首次即信任存下；再连比对，不匹配抛 `identityChanged`。
    /// 首信持久化失败会上抛底层错误（fail-closed）——信任锚未落盘绝不放行握手，
    /// 否则下次又当"首信"会重新信任对端出示的任意公钥，MITM 检测静默失效。
    ///
    /// 读取信任锚失败/损坏同样上抛（`try rememberedIdentity`）：只有明确"无记录（notFound）→ nil"
    /// 才走首信持久化；读到 notFound 以外错误或记录损坏则拒连，绝不覆盖已有信任锚、绝不当首信。
    func verifyOrTrust(machineKey: String, presentedPub: Data) throws {
        if let known = try rememberedIdentity(forMachineKey: machineKey) {
            guard known == presentedPub else { throw TOFUError.identityChanged }
        } else {
            try remember(presentedPub, forMachineKey: machineKey)
        }
    }
}

/// Keychain 持久实现（防篡改：存储被改 = TOFU 失效；别的 app / 越狱环境动不了）。
/// account 命名 `relay-tofu-<machineKey>`，一机器一记录。
struct KeychainTOFUStore: TOFUStoring {
    let keychain: KeychainStore
    init(service: String = "com.codexremote.relay-tofu") {
        self.keychain = KeychainStore(service: service)
    }
    private func account(_ key: String) -> String { "relay-tofu-\(key)" }

    func rememberedIdentity(forMachineKey key: String) throws -> Data? {
        // `KeychainStore.load` 已区分：notFound → nil（确实无记录），其它 OSStatus → throw。
        // 这里不再用 `try?` 吞错——读失败会上抛，由 verifyOrTrust 传播为拒连（fail-closed）。
        guard let s = try keychain.load(account(key)) else { return nil }
        // 本轮关严：字符串存在但非法 base64 → 抛「记录损坏」（不再返回 nil 当无记录 → 覆盖信任锚）。
        guard let data = Data(base64Encoded: s) else { throw TOFUError.recordCorrupted }
        return data
    }
    func remember(_ identityPub: Data, forMachineKey key: String) throws {
        try keychain.save(identityPub.base64EncodedString(), for: account(key))
    }
}
