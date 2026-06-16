import XCTest

final class ConnectionConfigLayoutTests: XCTestCase {
    func testPortFieldIsRenderedAfterKeyArea() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexRemote/Views/ConnectionConfigView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let userField = try XCTUnwrap(source.range(of: "TextField(\"conn.sshUser\""))
        let keyArea = try XCTUnwrap(source.range(of: "KeyAreaView()"))
        let portField = try XCTUnwrap(source.range(of: "TextField(\"conn.sshPort\""))

        XCTAssertLessThan(userField.lowerBound, keyArea.lowerBound)
        XCTAssertLessThan(keyArea.lowerBound, portField.lowerBound)
    }
}
