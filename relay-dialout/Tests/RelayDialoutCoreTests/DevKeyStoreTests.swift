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
