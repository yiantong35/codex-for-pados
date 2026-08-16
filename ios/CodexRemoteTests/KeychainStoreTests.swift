import XCTest
import Security
@testable import CodexRemote

private final class FakeKeychainAccess: KeychainAccessing, @unchecked Sendable {
    var value: Data?
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    private(set) var addCount = 0

    func add(_ attributes: CFDictionary) -> OSStatus {
        addCount += 1
        if addStatus == errSecSuccess {
            value = (attributes as NSDictionary)[kSecValueData] as? Data
        }
        return addStatus
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        if updateStatus == errSecSuccess {
            value = (attributes as NSDictionary)[kSecValueData] as? Data
        }
        return updateStatus
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let value else { return errSecItemNotFound }
        result?.pointee = value as CFData
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        guard value != nil else { return errSecItemNotFound }
        value = nil
        return errSecSuccess
    }
}

final class KeychainStoreTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let store = KeychainStore(service: "com.codexremote.test")
        // 清理可能的残留，保证测试可重复运行。
        try? store.delete("ssh-credential")

        try store.save("secret-key", for: "ssh-credential")
        XCTAssertEqual(try store.load("ssh-credential"), "secret-key")
        try store.delete("ssh-credential")
        XCTAssertNil(try store.load("ssh-credential"))
    }

    func testUpdateFailurePreservesExistingValueAndDoesNotAdd() throws {
        let access = FakeKeychainAccess()
        access.value = Data("old-identity".utf8)
        access.updateStatus = errSecInteractionNotAllowed
        let store = KeychainStore(service: "test", access: access)

        XCTAssertThrowsError(try store.save("new-identity", for: "identity"))
        XCTAssertEqual(String(data: try XCTUnwrap(access.value), encoding: .utf8), "old-identity")
        XCTAssertEqual(access.addCount, 0)
    }

    func testNotFoundThenAddFailureDoesNotDeleteValueCreatedByRace() {
        let access = FakeKeychainAccess()
        access.value = Data("concurrent-old-value".utf8)
        access.updateStatus = errSecItemNotFound
        access.addStatus = errSecDuplicateItem
        let store = KeychainStore(service: "test", access: access)

        XCTAssertThrowsError(try store.save("new-value", for: "identity"))
        XCTAssertEqual(String(data: access.value!, encoding: .utf8), "concurrent-old-value")
        XCTAssertEqual(access.addCount, 1)
    }

    func testMissingRecordUsesAdd() throws {
        let access = FakeKeychainAccess()
        access.updateStatus = errSecItemNotFound
        let store = KeychainStore(service: "test", access: access)

        try store.save("new-value", for: "identity")
        XCTAssertEqual(String(data: try XCTUnwrap(access.value), encoding: .utf8), "new-value")
        XCTAssertEqual(access.addCount, 1)
    }

    func testInvalidUTF8RecordThrowsInsteadOfReportingMissing() {
        let access = FakeKeychainAccess()
        access.value = Data([0xFF])
        let store = KeychainStore(service: "test", access: access)

        XCTAssertThrowsError(try store.load("identity")) { error in
            guard let keychainError = error as? KeychainStore.KeychainError,
                  case .os(errSecDecode) = keychainError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
