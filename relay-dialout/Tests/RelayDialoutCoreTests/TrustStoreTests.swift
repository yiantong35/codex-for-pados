import Testing
import Foundation
@testable import RelayDialoutCore

private func tmpDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func trustStoreAddThenLoadRoundTrip() throws {
    let dir = try tmpDir()
    let store = try TrustStore(dir: dir)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: "iPad-A")
    let reloaded = try TrustStore(dir: dir)
    #expect(reloaded.record(forPubB64: "PUB1")?.stableSessionId == "S1")
    #expect(reloaded.record(forPubB64: "PUB1")?.label == "iPad-A")
}

@Test func trustStoreRevokeSingle() throws {
    let dir = try tmpDir()
    let store = try TrustStore(dir: dir)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: nil)
    try store.trust(ipadPubB64: "PUB2", stableSessionId: "S2", label: nil)
    try store.revoke(ipadPubB64: "PUB1")
    #expect(store.record(forPubB64: "PUB1") == nil)
    #expect(store.record(forPubB64: "PUB2") != nil)
}

@Test func trustStoreClearAll() throws {
    let dir = try tmpDir()
    let store = try TrustStore(dir: dir)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: nil)
    try store.clearAll()
    #expect(store.all().isEmpty)
}

@Test func trustStoreTrustSamePubUpdatesInPlace() throws {
    let dir = try tmpDir()
    let store = try TrustStore(dir: dir)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: nil)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: "renamed")  // 幂等更新，不重复
    #expect(store.all().count == 1)
    #expect(store.record(forPubB64: "PUB1")?.stableSessionId == "S1")
}

@Test func trustStoreWritesFileWith0600PermissionsAndDir0700() throws {
    // 目录不能预先存在：要断言 TrustStore 自己创建目录时用的权限，若 tmpDir() 预建目录，
    // init 会因目录已存在而跳过 0700 设置，断言就测不到真实行为（同 DevKeyStoreTests 手法）。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try TrustStore(dir: dir)
    try store.trust(ipadPubB64: "PUB1", stableSessionId: "S1", label: nil)

    let filePath = dir.appendingPathComponent("trusted-ipads.json").path
    let fileAttrs = try FileManager.default.attributesOfItem(atPath: filePath)
    let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue
    #expect(filePerms == 0o600)

    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
    #expect(dirPerms == 0o700)
}

@Test func trustStoreCorruptedFileFailsClosed() throws {
    let dir = try tmpDir()
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("trusted-ipads.json"))
    #expect(throws: TrustStore.TrustStoreError.self) {
        _ = try TrustStore(dir: dir)
    }
}
