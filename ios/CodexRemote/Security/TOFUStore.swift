import Foundation

/// TOFU 校验失败：开发机身份公钥与首次记住的不一致（可能中间人替换）。
enum TOFUError: Error, Equatable { case identityChanged }

/// iPad 单边 TOFU 信任存储抽象：按机器稳定键记开发机身份公钥。
protocol TOFUStoring: Sendable {
    /// 取该机器键已记住的开发机身份公钥；无则 nil。
    func rememberedIdentity(forMachineKey key: String) -> Data?
    /// 记住该机器键的开发机身份公钥（覆盖式）。持久化失败必须上抛（fail-closed）。
    func remember(_ identityPub: Data, forMachineKey key: String) throws
}

extension TOFUStoring {
    /// 首次即信任存下；再连比对，不匹配抛 `identityChanged`。
    /// 首信持久化失败会上抛底层错误（fail-closed）——信任锚未落盘绝不放行握手，
    /// 否则下次又当"首信"会重新信任对端出示的任意公钥，MITM 检测静默失效。
    func verifyOrTrust(machineKey: String, presentedPub: Data) throws {
        if let known = rememberedIdentity(forMachineKey: machineKey) {
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

    func rememberedIdentity(forMachineKey key: String) -> Data? {
        guard let s = (try? keychain.load(account(key))) ?? nil else { return nil }
        return Data(base64Encoded: s)
    }
    func remember(_ identityPub: Data, forMachineKey key: String) throws {
        try keychain.save(identityPub.base64EncodedString(), for: account(key))
    }
}
