import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import RelayProtocol
import RelayServerCore

/// relay 中继服务端(SwiftNIO ws)。
///
/// 职责极简且**零知识**:按 `/relay/{sessionId}` + header `x-role`(devMachine/iPad)
/// 撮合一对连接,握手后纯密文双向透传——iPad 发来的帧转给 dev,dev 发来的转给 iPad。
/// relay **绝不解密、绝不解析帧内容**(端到端加密由 RelayProtocol 保证)。
///
/// - `GET /relay/{sessionId}` + ws upgrade + `x-role` header → 撮合房间。
/// - `GET /health`(非 upgrade)→ `{"ok":true}` 200。

let port = Int(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "") ?? 9000
let host = "0.0.0.0"
let rooms = RelayRooms()
let limiter = RelayLimiter(maxPerIP: RelayLimits.maxConnectionsPerIP,
                           maxRooms: RelayLimits.maxRooms,
                           ratePerMinute: RelayLimits.connectRatePerMinute)

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: RelayLimits.maxMessageBytes,   // 单帧上限；分片累积上限由 FrameAccumulator 兜底
            shouldUpgrade: { (channel, head) -> EventLoopFuture<HTTPHeaders?> in
                let role = head.headers.first(name: "x-role")
                if UpgradeRequest.parseUpgrade(uri: head.uri, role: role) != nil {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                } else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
            },
            upgradePipelineHandler: { (channel, head) -> EventLoopFuture<Void> in
                let role = head.headers.first(name: "x-role")
                guard let parsed = UpgradeRequest.parseUpgrade(uri: head.uri, role: role) else {
                    return channel.eventLoop.makeFailedFuture(RelayError.badUpgrade)
                }
                // 取来源 IP 用于 per-IP 并发/速率配额(准入在 handlerAdded 内,升级已定才计数)。
                let ip = channel.remoteAddress?.ipAddress ?? "unknown"
                // 先插 IdleStateHandler(空闲超时回收连接),再插撮合 handler。
                return channel.pipeline.addHandler(
                    IdleStateHandler(allTimeout: .seconds(RelayLimits.idleTimeoutSeconds))
                ).flatMap {
                    channel.pipeline.addHandler(
                        RelayConnectionHandler(rooms: rooms, limiter: limiter, ip: ip,
                                               sessionId: parsed.sessionId, role: parsed.role,
                                               maxMessageBytes: RelayLimits.maxMessageBytes)
                    )
                }
            }
        )
        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
            withErrorHandling: true
        ).flatMap {
            // 非 upgrade 请求(如 GET /health)由 HealthHandler 处理。
            channel.pipeline.addHandler(HealthHandler())
        }
    }

enum RelayError: Error { case badUpgrade }

let serverChannel = try bootstrap.bind(host: host, port: port).wait()
print("relay-server listening on \(host):\(port)")
try serverChannel.closeFuture.wait()
try? group.syncShutdownGracefully()

/// 单个 ws 连接:接入房间,双向桥接密文帧。
final class RelayConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let rooms: RelayRooms
    private let limiter: RelayLimiter            // 资源配额（4.3，D3）
    private let ip: String                       // 来源 IP（per-IP 并发/速率）
    private let sessionId: String
    private let role: RelayPeer
    private var accumulator: FrameAccumulator   // 单消息字节上限累积器（4.1）
    private var connId: UUID?                    // 本连接的唯一身份（3.4，D4）
    private var admitted = false                 // 本连接是否已计入配额（决定 remove 时是否释放）
    private var admittedRoom = false             // 本连接是否已计入房间配额

    init(rooms: RelayRooms, limiter: RelayLimiter, ip: String,
         sessionId: String, role: RelayPeer, maxMessageBytes: Int) {
        self.rooms = rooms
        self.limiter = limiter
        self.ip = ip
        self.sessionId = sessionId
        self.role = role
        self.accumulator = FrameAccumulator(maxBytes: maxMessageBytes)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // 资源准入(升级已定才计数):速率 + per-IP 并发。超限即关连接,不进撮合。
        guard limiter.admit(ip: ip, now: Date().timeIntervalSince1970) else {
            context.close(promise: nil)
            return
        }
        admitted = true
        // 房间总数配额:超上限拒(fail-closed)。
        guard limiter.admitRoom(sessionId: sessionId) else {
            context.close(promise: nil)
            return
        }
        admittedRoom = true

        // sink:把对端投来的密文字符串编成 ws text frame 写回本连接。
        let channel = context.channel
        let result = rooms.join(sessionId: sessionId, role: role) { frame in
            channel.eventLoop.execute {
                var buf = channel.allocator.buffer(capacity: frame.utf8.count)
                buf.writeString(frame)
                let wsFrame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(wsFrame, promise: nil)
            }
        }
        switch result {
        case .joined(let id):
            self.connId = id
        case .rejectedRoleOccupied:
            // 后到同角色被拒:主动关连接,不接管先到转发(D4)。
            context.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // 仅按本连接自己的 connId 精确 leave;被拒连接(connId 为 nil)不误清占用槽的先到连接。
        if let id = connId {
            rooms.leave(sessionId: sessionId, role: role, connId: id)
        }
        // 对称释放配额:仅释放本连接实际计入过的部分。
        // 房间用引用计数,每次成功 admitRoom 对应一次 releaseRoom,房间仅在最后一端离开才释放。
        if admittedRoom { limiter.releaseRoom(sessionId: sessionId) }
        if admitted { limiter.release(ip: ip) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)   // 空闲超时:回收连接释放资源(4.2)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .continuation:
            switch accumulator.append(Array(frame.unmaskedData.readableBytesView), fin: frame.fin) {
            case .accumulating:
                break
            case .complete(let payload):
                // 零知识:不解析 payload,原样转给对端。
                rooms.forward(sessionId: sessionId, from: role, frame: payload)
            case .overflow:
                context.close(promise: nil)   // 超单消息上限:关连接,内存不无界增长
            }
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            var frameData = frame.data
            if let key = frame.maskKey { frameData.webSocketUnmask(key) }
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }
}

/// 非 ws 请求处理:GET /health → {"ok":true}。其余 → 404。
final class HealthHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var keepAlive = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            keepAlive = head.isKeepAlive
            let isHealth = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) == "/health"
            let status: HTTPResponseStatus = isHealth ? .ok : .notFound
            let bodyString = isHealth ? "{\"ok\":true}" : "not found"
            var buffer = context.channel.allocator.buffer(capacity: bodyString.utf8.count)
            buffer.writeString(bodyString)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
            let responseHead = HTTPResponseHead(version: head.version, status: status, headers: headers)
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            if !keepAlive { context.close(promise: nil) }
        case .body, .end:
            break
        }
    }
}
