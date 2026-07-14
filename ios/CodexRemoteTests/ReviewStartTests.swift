import Testing
import Foundation
@testable import CodexRemote

struct ReviewStartTests {
    @Test func reviewStartMethodConstant() {
        #expect(RPCMethod.reviewStart == "review/start")
    }
}
