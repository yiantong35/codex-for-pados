import Testing
import Foundation
import Crypto
@testable import RelayDialoutCore

@Test func devKeyStorePersistsAndReloads() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s1 = try DevKeyStore(dir: dir)
    let idPub1 = s1.identityPublicKeyRaw
    let s2 = try DevKeyStore(dir: dir)   // 重新加载
    #expect(s2.identityPublicKeyRaw == idPub1)   // 幂等复用
}

@Test func devKeyStoreDoesNotPersistExchangeKey() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try DevKeyStore(dir: dir)
    // 前向保密：只应持久化 identity.key；交换密钥每会话新生，绝不落 exchange.key。
    let exchangeURL = dir.appendingPathComponent("exchange.key")
    #expect(!FileManager.default.fileExists(atPath: exchangeURL.path))
    let identityURL = dir.appendingPathComponent("identity.key")
    #expect(FileManager.default.fileExists(atPath: identityURL.path))
}

@Test func devKeyStoreRemovesLegacyExchangeKeyOnInit() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 预置旧版本遗留的交换私钥文件。
    let exchangeURL = dir.appendingPathComponent("exchange.key")
    try Data(Curve25519.KeyAgreement.PrivateKey().rawRepresentation).write(to: exchangeURL)
    _ = try DevKeyStore(dir: dir)
    #expect(!FileManager.default.fileExists(atPath: exchangeURL.path))   // 遗留交换私钥被清理
}

@Test func devKeyStoreThrowsOnCorruptedKeyFileInsteadOfOverwriting() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 预置损坏的 identity.key（长度不对，无法 init Ed25519 key）。
    let identityURL = dir.appendingPathComponent("identity.key")
    let garbage = Data("garbage".utf8)
    try garbage.write(to: identityURL)

    #expect(throws: (any Error).self) {
        _ = try DevKeyStore(dir: dir)
    }
    // 损坏文件绝不被新密钥覆盖：读回仍是 "garbage"。
    let after = try Data(contentsOf: identityURL)
    #expect(after == garbage)
}

@Test func devKeyStoreThrowsOnUnreadableKeyFileInsteadOfOverwriting() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // #8：现在加载前会 chmod 收紧到 0600，0o000 会被收紧成可读而不再触发不可读分支；
    // 改用「identity.key 处放一个目录」构造仍然可读失败的场景——
    //   lstat 非软链、属主==当前 uid、chmod 目录成功，但 `Data(contentsOf:)` 对目录读失败。
    // 依旧验证 fail-closed 不变量：存在但读失败 → throw，绝不当"不存在"用新密钥覆盖。
    let identityURL = dir.appendingPathComponent("identity.key")
    try FileManager.default.createDirectory(at: identityURL, withIntermediateDirectories: true)

    // 存在但读失败 → 必须 throw，绝不覆盖。
    #expect(throws: (any Error).self) {
        _ = try DevKeyStore(dir: dir)
    }
    // 该路径仍是目录（未被新密钥文件覆盖）。
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: identityURL.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
}

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

/// #8：属主不符 fail-closed。普通测试进程无法 `chown` 到别的 uid 而不提权，
/// 故直接对抽出的纯函数 `validateOwner` 注入合成的「文件属主 != 当前 uid」验证抛错。
@Test func devKeyStoreRejectsOwnerMismatch() throws {
    // 属主一致：不抛。
    try DevKeyStore.validateOwner(uid: 501, fileUid: 501, path: "/tmp/identity.key")
    // 属主不符：抛 insecureKeyFile。
    #expect(throws: DevKeyStore.DevKeyStoreError.insecureKeyFile("/tmp/identity.key")) {
        try DevKeyStore.validateOwner(uid: 501, fileUid: 0, path: "/tmp/identity.key")
    }
}

@Test func devKeyStoreWritesFilesWith0600Permissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try DevKeyStore(dir: dir)
    // 只持久化 identity.key（交换密钥每会话新生不落盘）。
    for name in ["identity.key"] {
        let path = dir.appendingPathComponent(name).path
        #expect(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }
}
