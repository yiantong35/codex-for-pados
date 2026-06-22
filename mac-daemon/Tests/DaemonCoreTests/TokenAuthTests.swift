import XCTest
@testable import DaemonCore

/// 从 WS 握手 URI 的 query 参数提取并校验预共享 token。
final class TokenAuthTests: XCTestCase {

    func testExtractsTokenFromQuery() {
        XCTAssertEqual(TokenAuth.extractToken(fromURI: "/?token=abc"), "abc")
    }

    func testExtractsAmongMultipleParams() {
        XCTAssertEqual(TokenAuth.extractToken(fromURI: "/ws?foo=1&token=abc&bar=2"), "abc")
    }

    func testNoQueryReturnsNil() {
        XCTAssertNil(TokenAuth.extractToken(fromURI: "/ws"))
    }

    func testTokenAbsentAmongParamsReturnsNil() {
        XCTAssertNil(TokenAuth.extractToken(fromURI: "/?foo=1&bar=2"))
    }

    func testEmptyTokenValue() {
        XCTAssertEqual(TokenAuth.extractToken(fromURI: "/?token="), "")
    }

    func testAuthorizeMatch() {
        XCTAssertTrue(TokenAuth.authorize(uri: "/?token=secret", expected: "secret"))
    }

    func testAuthorizeMismatch() {
        XCTAssertFalse(TokenAuth.authorize(uri: "/?token=wrong", expected: "secret"))
    }

    func testAuthorizeMissingTokenRejected() {
        XCTAssertFalse(TokenAuth.authorize(uri: "/ws", expected: "secret"))
    }

    func testAuthorizeEmptyExpectedRejected() {
        // 配置缺失(expected 为空)不应放行任何连接
        XCTAssertFalse(TokenAuth.authorize(uri: "/?token=", expected: ""))
    }
}
