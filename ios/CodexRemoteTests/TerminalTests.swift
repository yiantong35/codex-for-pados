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

    @MainActor @Test func outputDeltaForwardsRawBytesToCallback() {
        let s = TerminalSession()
        var received: [UInt8] = []
        s.onBytes = { received.append(contentsOf: $0) }
        s.start(cwd: "/repo")
        let pid = s.processId!
        // 多字节 UTF-8（中文）验证字节路径不经 String 破坏
        let payload = Array("你好hi".utf8)
        s.handleOutputDelta(processId: pid, base64: Data(payload).base64EncodedString())
        #expect(received == payload)
        // 非当前 processId 的 delta 被忽略
        received.removeAll()
        s.handleOutputDelta(processId: "other", base64: Data("x".utf8).base64EncodedString())
        #expect(received.isEmpty)
    }

    @MainActor @Test func capReachedForwardsTruncationBytes() {
        let s = TerminalSession()
        var text = ""
        s.onBytes = { text += String(decoding: $0, as: UTF8.self) }
        s.start(cwd: "/repo")
        s.handleOutputDelta(processId: s.processId!, base64: Data("x".utf8).base64EncodedString(), capReached: true)
        #expect(text.contains("截断"))
    }

    @MainActor @Test func disconnectForwardsBreakBytes() {
        let s = TerminalSession()
        var text = ""
        s.onBytes = { text += String(decoding: $0, as: UTF8.self) }
        s.start(cwd: "/repo")
        s.handleReconnecting()
        #expect(text.contains("──"))
        #expect(!text.contains("已重连"))
        #expect(s.processId == nil)
    }

    @MainActor @Test func reconnectRestartsWithNewProcessId() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let old = s.processId
        s.handleReconnecting()
        s.start(cwd: "/repo")
        #expect(s.processId != old)
    }

    @MainActor @Test func reconnectSuccessAppearsOnlyAfterReady() {
        let s = TerminalSession()
        var text = ""
        s.onBytes = { text += String(decoding: $0, as: UTF8.self) }
        s.handleReconnecting()
        #expect(!text.contains(L10n.string("terminal.reconnected", locale: LocaleManager.currentLocale)))
        s.handleReconnectSucceeded()
        #expect(text.contains(L10n.string("terminal.reconnected", locale: LocaleManager.currentLocale)))
    }

    // #4 手动重连重绑：attach 新 rpc 实例后——
    //   ① stale processId 复位（旧 pid 属已断连接上的 shell，新连接无此进程）；
    //   ② outputDelta 观察者重订阅到新 rpc（旧实现 guard observer==nil → 仍绑旧流，
    //      新连接 shell 输出永不显示）。
    @MainActor @Test func reconnectRebindsAndClearsStaleProcessId() async throws {
        let mockA = MockTransport()
        let rpcA = JSONRPCClient(transport: mockA)
        await rpcA.start()
        let mockB = MockTransport()
        let rpcB = JSONRPCClient(transport: mockB)
        await rpcB.start()

        let s = TerminalSession()
        await s.attach(rpc: rpcA)
        s.start(cwd: "/repo")
        #expect(s.processId != nil)

        await s.attach(rpc: rpcB)                 // 模拟完整重连：新 rpc 实例
        #expect(s.processId == nil)               // ① stale 复位 → 令 startIfNeeded 重起

        // ② 新连接上起新 shell，经 rpcB 真实流喂 outputDelta，应回调 onBytes（观察者已重订阅）。
        var received: [UInt8] = []
        s.onBytes = { received.append(contentsOf: $0) }
        s.start(cwd: "/repo")
        let pid = s.processId!
        let payload = Array("hi".utf8)
        await mockB.feed(#"{"method":"command/exec/outputDelta","params":{"processId":"\#(pid)","deltaBase64":"\#(Data(payload).base64EncodedString())"}}"#)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(received == payload)
    }

    @MainActor @Test func sessionWriteParams() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let p = s.makeWriteParams(input: "ls\n")
        #expect(p?.processId == s.processId)
        #expect(p?.deltaBase64 == Data("ls\n".utf8).base64EncodedString())
    }
    @MainActor @Test func startIfNeededFollowsCwd() {
        let s = TerminalSession()
        s.startIfNeeded(cwd: "/a")
        let pidA = s.processId
        s.startIfNeeded(cwd: "/a")          // 同 cwd 不重起
        #expect(s.processId == pidA)
        s.startIfNeeded(cwd: "/b")          // cwd 变 → 重起
        #expect(s.processId != pidA)
    }

    // MARK: - Task 4: SwiftTermView 桥接

    @MainActor @Test func bridgeSendForwardsUTF8ToSession() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let bridge = TerminalBridge(session: s)
        var sent: String?
        s.onInputForTest = { sent = $0 }
        bridge.handleSend(bytes: ArraySlice(Array("ls\n".utf8)))
        #expect(sent == "ls\n")
    }

    @MainActor @Test func bridgeSizeChangedForwardsResize() {
        let s = TerminalSession()
        s.start(cwd: "/repo")
        let bridge = TerminalBridge(session: s)
        var got: CommandExecTerminalSize?
        s.onResizeForTest = { got = $0 }
        bridge.handleSizeChanged(newCols: 100, newRows: 30)
        #expect(got?.cols == 100)
        #expect(got?.rows == 30)
    }
}
