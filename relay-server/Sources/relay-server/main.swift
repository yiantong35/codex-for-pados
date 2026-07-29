import Foundation
import NIOCore
import NIOPosix
import RelayServerCore

/// relay 中继服务端(SwiftNIO ws)。
///
/// 职责极简且**零知识**:按 `/relay/{sessionId}` + header `x-role`(devMachine/iPad)
/// 撮合一对连接,握手后纯密文双向透传——iPad 发来的帧转给 dev,dev 发来的转给 iPad。
/// relay **绝不解密、绝不解析帧内容**(端到端加密由 RelayProtocol 保证)。
///
/// - `GET /relay/{sessionId}` + ws upgrade + `x-role` header → 撮合房间。
/// - `GET /health`(非 upgrade)→ `{"ok":true}` 200。
///
/// 管线装配(计数 + 空闲超时 + HTTP/upgrade + 撮合)全部收敛到 RelayServerCore 的
/// `configureRelayPipeline`;per-IP 并发/速率限流已上移到反向代理(见 DEPLOY.md)。

let port = Int(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "") ?? 9000
let host = RelayServerConfig.resolveHost(env: ProcessInfo.processInfo.environment)
let rooms = RelayRooms()
let limiter = RelayLimiter(maxTotalConnections: RelayLimits.maxTotalConnections,
                           maxRooms: RelayLimits.maxRooms)

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        configureRelayPipeline(channel: channel, rooms: rooms, limiter: limiter)
    }

let serverChannel = try bootstrap.bind(host: host, port: port).wait()
print("relay-server listening on \(host):\(port)")
try serverChannel.closeFuture.wait()
try? group.syncShutdownGracefully()
