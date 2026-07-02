import Foundation

// MARK: - 终端 command/exec（下边栏终端）

struct CommandExecTerminalSize: Codable, Equatable { let rows: Int; let cols: Int }

struct CommandExecParams: Encodable {
    let command: [String]
    var processId: String?
    var tty: Bool?
    var streamStdin: Bool?
    var streamStdoutStderr: Bool?
    var cwd: String?
    var size: CommandExecTerminalSize?
}

struct CommandExecWriteParams: Encodable {
    let processId: String
    var deltaBase64: String?
    var closeStdin: Bool?
}

struct CommandExecResizeParams: Encodable {
    let processId: String
    let size: CommandExecTerminalSize
}

struct CommandExecTerminateParams: Encodable { let processId: String }

/// command/exec/outputDelta 广播 payload。
struct CommandExecOutputDeltaNotification: Decodable, Equatable {
    let processId: String
    let stream: String        // "stdout" | "stderr"
    let deltaBase64: String
    var capReached: Bool?
}
