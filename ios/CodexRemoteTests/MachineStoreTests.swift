import XCTest
@testable import CodexRemote

@MainActor
final class MachineStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_emptyWhenNothingStored() {
        let store = MachineStore(defaults: freshDefaults())
        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertNil(store.activeMachineId)
    }

    func test_addPersistsAndRestores() {
        let d = freshDefaults()
        let s1 = MachineStore(defaults: d)
        let m = MachineConfig(host: "h1", user: "u1")
        s1.add(m)
        let s2 = MachineStore(defaults: d)   // 重启模拟
        XCTAssertEqual(s2.machines.count, 1)
        XCTAssertEqual(s2.machines.first?.host, "h1")
    }

    func test_migratesLegacySingleConfig() {
        let d = freshDefaults()
        d.set("legacyHost", forKey: "host")
        d.set("legacyUser", forKey: "sshUser")
        d.set("2222", forKey: "sshPort")
        let store = MachineStore(defaults: d)
        XCTAssertEqual(store.machines.count, 1)
        XCTAssertEqual(store.machines.first?.host, "legacyHost")
        XCTAssertEqual(store.machines.first?.user, "legacyUser")
        XCTAssertEqual(store.machines.first?.sshPort, 2222)
        XCTAssertEqual(store.activeMachineId, store.machines.first?.id)
        XCTAssertEqual(d.string(forKey: "host"), "legacyHost")   // 旧 key 保留一版
    }

    func test_noMigrationWhenMachinesAlreadyExist() {
        let d = freshDefaults()
        let s1 = MachineStore(defaults: d)
        s1.add(MachineConfig(host: "existing", user: "u"))
        d.set("legacyHost", forKey: "host")
        let s2 = MachineStore(defaults: d)
        XCTAssertEqual(s2.machines.count, 1)
        XCTAssertEqual(s2.machines.first?.host, "existing")
    }

    func test_capAt10() {
        let store = MachineStore(defaults: freshDefaults())
        for i in 0..<10 { store.add(MachineConfig(host: "h\(i)", user: "u")) }
        XCTAssertEqual(store.machines.count, 10)
        XCTAssertFalse(store.canAddMore)
        let ok = store.add(MachineConfig(host: "overflow", user: "u"))
        XCTAssertFalse(ok)
        XCTAssertEqual(store.machines.count, 10)
    }

    func test_removeDeletesMachine() {
        let store = MachineStore(defaults: freshDefaults())
        let m = MachineConfig(host: "h", user: "u")
        store.add(m)
        store.remove(id: m.id)
        XCTAssertTrue(store.machines.isEmpty)
    }
}
