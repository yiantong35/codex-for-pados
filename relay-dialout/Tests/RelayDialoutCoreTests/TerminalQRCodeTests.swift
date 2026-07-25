import Testing
import Foundation
@testable import RelayDialoutCore

@Test func qrMatrixNonEmptyAndSquare() throws {
    let m = try TerminalQRCode.matrix(for: "codexrelay://pair?relay=wss://x&sid=s&pk=p&pc=c&exp=1")
    #expect(m.count > 0)
    #expect(m.count == (m.first?.count ?? -1))   // 方阵
}

@Test func halfBlockRenderProducesBlockChars() throws {
    let s = try TerminalQRCode.halfBlockString(for: "codexrelay://pair?x")
    #expect(s.contains("▀") || s.contains("▄") || s.contains("█") || s.contains(" "))
    #expect(s.contains("\n"))
}

@Test func differentPayloadsDifferentMatrices() throws {
    let a = try TerminalQRCode.halfBlockString(for: "codexrelay://pair?sid=A")
    let b = try TerminalQRCode.halfBlockString(for: "codexrelay://pair?sid=B")
    #expect(a != b)
}
