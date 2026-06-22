import Foundation
import DaemonCore

// MARK: - 参数解析

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let port = Int(argValue("--port") ?? "") ?? 8765
let token: String = argValue("--token") ?? {
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}()

// MARK: - 组装 AppServerConn ↔ Hub ↔ WSServer
//
// Hub 需要把下游 request 透传给 AppServerConn,而 AppServerConn 又要把输出喂给 Hub。
// 两者互相引用,用 ConnRef 做延迟绑定打破循环。

final class ConnRef: @unchecked Sendable {
    var conn: AppServerConn?
}
let connRef = ConnRef()

let hub = Hub(sendToAppServer: { data in
    let c = connRef.conn
    Task { await c?.send(data) }
})

let conn = AppServerConn(onLine: { line in
    Task { await hub.ingestFromAppServer(line) }
})
connRef.conn = conn

let ws = WSServer(port: port, token: token, hub: hub)

// MARK: - 启动

do {
    try await conn.start()
    let addr = try ws.start()
    FileHandle.standardError.write(Data("""
    ──────────────────────────────────────────
     Codex 广播 daemon 已启动
      监听     : \(addr)
      端口     : \(port)
      token    : \(token)
      下游连接 : ws://<MAC_LAN_IP>:\(port)/?token=\(token)
    ──────────────────────────────────────────

    """.utf8))
} catch {
    FileHandle.standardError.write(Data("启动失败: \(error)\n".utf8))
    exit(1)
}

// MARK: - 信号处理:优雅关闭(只 terminate 自己 spawn 的 app-server)

func installSignalHandler(_ sig: Int32) {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        FileHandle.standardError.write(Data("\n收到信号,正在关闭…\n".utf8))
        ws.stop()
        let sem = DispatchSemaphore(value: 0)
        Task { await conn.shutdown(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
        exit(0)
    }
    src.resume()
    // 持有 source,避免被释放
    signalSources.append(src)
}

var signalSources: [DispatchSourceSignal] = []
installSignalHandler(SIGINT)
installSignalHandler(SIGTERM)

// 阻塞运行
dispatchMain()
