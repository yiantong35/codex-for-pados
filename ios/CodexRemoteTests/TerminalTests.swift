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
}
