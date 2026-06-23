import XCTest

final class ConnectionConfigLayoutTests: XCTestCase {
    func testPortFieldIsRenderedAfterTokenAndKeyArea() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexRemote/Views/ConnectionConfigView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let tokenField = try XCTUnwrap(source.range(of: "SecureField(\"conn.token\""))
        let keyArea = try XCTUnwrap(source.range(of: "KeyAreaView()"))
        let portField = try XCTUnwrap(source.range(of: "TextField(\"conn.port\""))

        XCTAssertLessThan(tokenField.lowerBound, keyArea.lowerBound)
        XCTAssertLessThan(keyArea.lowerBound, portField.lowerBound)
    }
}
