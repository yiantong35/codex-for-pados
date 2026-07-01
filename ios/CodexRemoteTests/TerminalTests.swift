import Testing
import Foundation
@testable import CodexRemote

struct TerminalTests {
    private func decode<T: Decodable>(_ t: T.Type, _ j: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(j.utf8))
    }

    @Test func methodConstants() {
        #expect(RPCMethod.commandExec == "command/exec")
        #expect(RPCMethod.commandExecWrite == "command/exec/write")
        #expect(RPCMethod.commandExecResize == "command/exec/resize")
        #expect(RPCMethod.commandExecTerminate == "command/exec/terminate")
        #expect(ServerNotificationMethod.commandExecOutputDelta == "command/exec/outputDelta")
    }
    @Test func execParamsShape() throws {
        let p = CommandExecParams(command: ["/bin/zsh", "-i"], processId: "pid1", tty: true, cwd: "/repo",
                                  size: CommandExecTerminalSize(rows: 24, cols: 80))
        let j = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(j.contains("\"tty\":true"))
        #expect(j.contains("\"processId\":\"pid1\""))
        #expect(j.contains("repo"))   // cwd 存在（JSONEncoder 转义 / 为 \/，不断言完整路径）
    }
    @Test func decodeOutputDelta() throws {
        let n = try decode(CommandExecOutputDeltaNotification.self,
            #"{"processId":"pid1","stream":"stdout","deltaBase64":"aGVsbG8=","capReached":false}"#)
        #expect(n.processId == "pid1")
        #expect(n.deltaBase64 == "aGVsbG8=")
    }
    @Test func writeParamsShape() throws {
        let p = CommandExecWriteParams(processId: "pid1", deltaBase64: "bHM=", closeStdin: nil)
        let j = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(j.contains("\"processId\":\"pid1\""))
        #expect(j.contains("\"deltaBase64\":\"bHM=\""))
    }

    // MARK: - Task 2: ANSI 解析器

    @Test func ansiPlainText() {
        var p = ANSIParser()
        let runs = p.feed("hello world")
        #expect(runs.map(\.text).joined() == "hello world")
    }
    @Test func ansiColor() {
        var p = ANSIParser()
        let runs = p.feed("\u{1b}[31mred\u{1b}[0mplain")
        #expect(runs.count == 2)
        #expect(runs[0].text == "red")
        #expect(runs[0].color == .red)
        #expect(runs[1].text == "plain")
        #expect(runs[1].color == nil)
    }
    @Test func ansiSplitAcrossFeeds() {
        var p = ANSIParser()
        _ = p.feed("\u{1b}[3")
        let runs = p.feed("1mred")
        #expect(runs.contains { $0.text == "red" && $0.color == .red })
    }
    @Test func ansiCursorSeqDropped() {
        var p = ANSIParser()
        let runs = p.feed("a\u{1b}[2J\u{1b}[Hb")
        #expect(runs.map(\.text).joined() == "ab")
    }

    // MARK: - Task 3: TerminalSession

    @MainActor @Test func sessionConsumesOutputDelta() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let pid = s.processId!
        s.handleOutputDelta(processId: pid, base64: Data("hi".utf8).base64EncodedString())
        #expect(s.runs.map(\.text).joined().contains("hi"))
        s.handleOutputDelta(processId: "other", base64: Data("x".utf8).base64EncodedString())
        #expect(!s.runs.map(\.text).joined().contains("x"))
    }
    @MainActor @Test func sessionWriteParams() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let p = s.makeWriteParams(input: "ls\n")
        #expect(p?.processId == s.processId)
        #expect(p?.deltaBase64 == Data("ls\n".utf8).base64EncodedString())
    }
    @MainActor @Test func sessionReconnectMarksBreak() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let old = s.processId
        s.handleDisconnect()
        #expect(s.runs.map(\.text).joined().contains("──"))
        s.start(cwd: "/repo")
        #expect(s.processId != old)
    }
}
