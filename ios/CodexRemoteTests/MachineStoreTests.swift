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

    /// relay-only 机器构造 helper。
    private func relayMachine(_ name: String) -> MachineConfig {
        MachineConfig(displayName: name, relayURL: "wss://\(name)",
                      sessionId: "s-\(name)", devIdentityPubB64: "pk-\(name)")
    }

    func test_emptyWhenNothingStored() {
        let store = MachineStore(defaults: freshDefaults())
        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertNil(store.activeMachineId)
    }

    func test_addPersistsAndRestores() {
        let d = freshDefaults()
        let s1 = MachineStore(defaults: d)
        let m = relayMachine("m1")
        s1.add(m)
        let s2 = MachineStore(defaults: d)   // 重启模拟
        XCTAssertEqual(s2.machines.count, 1)
        XCTAssertEqual(s2.machines.first?.id, m.id)
        XCTAssertEqual(s2.machines.first?.relayURL, "wss://m1")
    }

    func test_capAt10() {
        let store = MachineStore(defaults: freshDefaults())
        for i in 0..<10 { store.add(relayMachine("h\(i)")) }
        XCTAssertEqual(store.machines.count, 10)
        XCTAssertFalse(store.canAddMore)
        let ok = store.add(relayMachine("overflow"))
        XCTAssertFalse(ok)
        XCTAssertEqual(store.machines.count, 10)
    }

    func test_removeDeletesMachine() {
        let store = MachineStore(defaults: freshDefaults())
        let m = relayMachine("h")
        store.add(m)
        store.remove(id: m.id)
        XCTAssertTrue(store.machines.isEmpty)
    }

    func test_loadKeepsValidRelayRecordsWhenLegacyArrayContainsSSHAndMalformedEntries() throws {
        let defaults = freshDefaults()
        let nestedRelayID = UUID()
        let legacySSHID = UUID()
        let currentRelayID = UUID()
        let records: [[String: Any]] = [
            [
                "id": nestedRelayID.uuidString,
                "displayName": "nested",
                "connection": [
                    "kind": "relay",
                    "relayURL": "wss://nested.example/ws",
                    "sessionId": "nested-session",
                    "devIdentityPubB64": "NESTED-PK",
                ],
            ],
            [
                "id": legacySSHID.uuidString,
                "displayName": "removed-ssh",
                "connection": [
                    "kind": "ssh",
                    "host": "old.example",
                    "user": "old-user",
                    "sshPort": 22,
                    "sockPath": "/tmp/old.sock",
                ],
            ],
            [
                "id": UUID().uuidString,
                "displayName": "broken-relay",
                "connection": ["kind": "relay"],
            ],
            [
                "id": currentRelayID.uuidString,
                "displayName": "current",
                "relayURL": "wss://current.example/ws",
                "sessionId": "current-session",
                "devIdentityPubB64": "CURRENT-PK",
            ],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: "machines")
        defaults.set(legacySSHID.uuidString, forKey: "activeMachineId")

        let store = MachineStore(defaults: defaults)

        XCTAssertEqual(store.machines.map(\.id), [nestedRelayID, currentRelayID])
        XCTAssertEqual(store.activeMachineId, nestedRelayID)

        let normalizedData = try XCTUnwrap(defaults.data(forKey: "machines"))
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedData) as? [[String: Any]]
        )
        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.allSatisfy { $0["relayURL"] != nil })
        XCTAssertTrue(normalized.allSatisfy { $0["connection"] == nil })
    }

    func test_loadDoesNotOverwriteNonemptyDataWhenEveryRecordIsInvalid() throws {
        let defaults = freshDefaults()
        let original = try JSONSerialization.data(withJSONObject: [["bad": true]])
        defaults.set(original, forKey: "machines")

        let store = MachineStore(defaults: defaults)

        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "machines"), original)
    }
}
