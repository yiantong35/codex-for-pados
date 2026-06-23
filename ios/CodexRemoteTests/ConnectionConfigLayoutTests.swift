import XCTest

final class ConnectionConfigLayoutTests: XCTestCase {
    func testPortFieldIsRenderedAfterToken() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexRemote/Views/ConnectionConfigView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let tokenField = try XCTUnwrap(source.range(of: "SecureField(\"conn.token\""))
        let portField = try XCTUnwrap(source.range(of: "TextField(\"conn.port\""))

        XCTAssertLessThan(tokenField.lowerBound, portField.lowerBound)
    }
}
