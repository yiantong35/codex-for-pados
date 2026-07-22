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

@Test func devKeyStoreExchangeKeyIsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s1 = try DevKeyStore(dir: dir)
    let exPub1 = s1.exchange.publicKey.rawRepresentation
    let s2 = try DevKeyStore(dir: dir)
    #expect(s2.exchange.publicKey.rawRepresentation == exPub1)
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
    defer {
        // 清理前恢复权限，否则 removeItem 也删不掉。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dir.appendingPathComponent("identity.key").path)
        try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 预置一把合法密钥，然后把文件设为不可读（模拟权限损坏 / IO 故障）。
    let identityURL = dir.appendingPathComponent("identity.key")
    let realKey = Curve25519.Signing.PrivateKey().rawRepresentation
    try realKey.write(to: identityURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: identityURL.path)

    // 文件存在但读失败 → 必须 throw，绝不当"不存在"用新密钥覆盖。
    #expect(throws: (any Error).self) {
        _ = try DevKeyStore(dir: dir)
    }
    // 恢复权限读回：内容仍是原密钥，未被覆盖。
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
    let after = try Data(contentsOf: identityURL)
    #expect(after == realKey)
}

@Test func devKeyStoreWritesFilesWith0600Permissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try DevKeyStore(dir: dir)
    for name in ["identity.key", "exchange.key"] {
        let path = dir.appendingPathComponent(name).path
        #expect(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }
}
