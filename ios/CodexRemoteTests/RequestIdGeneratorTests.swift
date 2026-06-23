import XCTest
@testable import CodexRemote

final class RequestIdGeneratorTests: XCTestCase {
    func testIdsAreUniqueAndPrefixed() {
        let a = RequestIdGenerator.next()
        let b = RequestIdGenerator.next()
        XCTAssertNotEqual(a, b)
        if case .string(let s) = a { XCTAssertTrue(s.hasPrefix("ipad-")) }
        else { XCTFail("应为 string id") }
    }
}
