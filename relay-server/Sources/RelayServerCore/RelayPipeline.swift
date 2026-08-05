import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import RelayProtocol

public enum RelayError: Error { case badUpgrade }

/// 管线头部（HEAD-ward）连接计数：装在 `configureHTTPServerPipeline` **之前**，穿越 ws upgrade 存活
/// （Task 1 D1 实证：HEAD-ward handler 穿越 upgrade 仍在管线且仍收 channelInactive），
/// 独占整条连接的**全局并发计数所有权**（D1 收敛点）。
///
/// - `channelActive`：全局准入，未达上限计数并放行；超限即关连接（不 fire，后续 handler 不启动）。
/// - `channelInactive`：仅释放曾 admit 成功者、且仅释放一次（连接级 `admitted` 标志防误释/双释）。
/// - `userInboundEventTriggered`：兜底响应 `IdleStateHandler.IdleStateEvent → close`，
///   保证 upgrade **之前**的慢连接/只连不发也被空闲回收（此刻管线里还没有 RelayConnectionHandler 消费该事件）。
public final class ConnectionCountHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    private let limiter: RelayLimiter
    private var admitted = false
    public init(limiter: RelayLimiter) { self.limiter = limiter }

    public func channelActive(context: ChannelHandlerContext) {
        guard limiter.admitConnection() else { context.close(promise: nil); return }
        admitted = true
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        if admitted { limiter.releaseConnection(); admitted = false }
        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            // 空闲超时兜底：upgrade 前 pipeline 尚无 RelayConnectionHandler 消费此事件，
            // 由 HEAD-ward 在此关连接，回收慢 upgrade / 只连不发的连接（channelInactive 会释放配额）。
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// 装配一条 relay child channel 的管线（HEAD-ward 计数 + 空闲超时，再 HTTP/upgrade）。
/// 计数与空闲超时在 upgrade **前**即对每条连接生效（覆盖 `/health`、未完成 HTTP、慢 upgrade）。
public func configureRelayPipeline(
    channel: Channel, rooms: RelayRooms, limiter: RelayLimiter,
    idleTimeoutSeconds: Int64 = RelayLimits.idleTimeoutSeconds,
    upgradedIdleTimeoutSeconds: Int64 = RelayLimits.upgradedIdleTimeoutSeconds,
    maxMessageBytes: Int = RelayLimits.maxMessageBytes) -> EventLoopFuture<Void> {

    let upgrader = NIOWebSocketServerUpgrader(
        maxFrameSize: maxMessageBytes,   // 单帧上限；分片累积上限由 FrameAccumulator 兜底
        shouldUpgrade: { (ch, head) -> EventLoopFuture<HTTPHeaders?> in
            let role = head.headers.first(name: "x-role")
            if UpgradeRequest.parseUpgrade(uri: head.uri, role: role) != nil {
                return ch.eventLoop.makeSucceededFuture(HTTPHeaders())
            }
            return ch.eventLoop.makeSucceededFuture(nil)
        },
        upgradePipelineHandler: { (ch, head) -> EventLoopFuture<Void> in
            let role = head.headers.first(name: "x-role")
            guard let parsed = UpgradeRequest.parseUpgrade(uri: head.uri, role: role) else {
                return ch.eventLoop.makeFailedFuture(RelayError.badUpgrade)
            }
            // F3 两段式解耦：upgrade 成功后，把 HEAD-ward 的握手期短空闲 handler（preUpgradeIdle）
            // 移除，换装一个远长于握手超时的长窗口 IdleStateHandler（upgradedIdle），装在
            // RelayConnectionHandler 之前（tail-ward）。这样：
            //   - 已升级健康连接改受长窗口约束——前台静置数分钟零额外流量、不被 120s 误回收；
            //   - 长窗口的 IdleStateEvent 沿 inbound 向尾部 fire 到 RelayConnectionHandler 消费（→ close），
            //     兜底回收真死连接，不产生无限存活僵尸；
            //   - HEAD-ward ConnectionCountHandler 位于 upgradedIdle 之前，收不到该事件、不重复关连接，
            //     其全局计数所有权（D1）不受影响。
            // post-upgrade handler 只做房间 admit/release + 转发，不再触碰全局连接配额（D1 收敛点）。
            // 升级成功后必须把 HealthHandler 移出管线：它的 InboundIn 是 HTTPServerRequestPart，
            // 升级后 HTTP 解码器已被 upgrade 流程摘除、ws 帧解码器接管，若 HealthHandler 仍在管线，
            // 对端投来的第一个 ws 数据帧会以原始字节/帧形态流到它，`unwrapInboundIn` 强转 HTTP 类型
            // 直接 Fatal（NIOAny 类型不匹配）→ 进程崩溃、两端连接同断。故 upgrade 后只保留
            // ws 解码器 + RelayConnectionHandler，HealthHandler 仅服务未升级的 HTTP（/health）。
            return ch.pipeline.removeHandler(name: "preUpgradeIdle").flatMap {
                ch.pipeline.removeHandler(name: "health")
            }.flatMap {
                ch.pipeline.addHandler(
                    IdleStateHandler(allTimeout: .seconds(upgradedIdleTimeoutSeconds)),
                    name: "upgradedIdle")
            }.flatMap {
                ch.pipeline.addHandler(
                    RelayConnectionHandler(rooms: rooms, limiter: limiter,
                                           sessionId: parsed.sessionId, role: parsed.role,
                                           maxMessageBytes: maxMessageBytes))
            }
        })

    // HEAD-ward：IdleStateHandler 与 ConnectionCountHandler 装在 HTTP 管线之前，穿越 upgrade 存活。
    // 顺序关键：IdleStateHandler 在前，ConnectionCountHandler 紧随其后——IdleStateHandler 的空闲事件
    // 沿 inbound **向尾部** fire，故消费该事件（→ close）的 ConnectionCountHandler 必须位于其 tail-ward，
    // 否则 upgrade 前的慢连接/只连不发无人消费 IdleStateEvent 而不被回收。
    // 该短空闲 handler 命名 preUpgradeIdle：upgrade 成功后被移除、换成长窗口 upgradedIdle（F3）。
    return channel.pipeline.addHandler(
        IdleStateHandler(allTimeout: .seconds(idleTimeoutSeconds)),
        name: "preUpgradeIdle").flatMap {
        channel.pipeline.addHandler(ConnectionCountHandler(limiter: limiter))
    }.flatMap {
        channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
            withErrorHandling: true)
    }.flatMap {
        // 非 upgrade 请求(如 GET /health)由 HealthHandler 处理。命名以便 upgrade 成功后移除。
        channel.pipeline.addHandler(HealthHandler(), name: "health")
    }
}

/// 单个 ws 连接:接入房间,双向桥接密文帧。
///
/// **计数所有权（D1）**：本 handler 只管房间 admit/release + `connId` 精确 leave + 转发；
/// 整条连接的**全局并发计数**由 HEAD-ward `ConnectionCountHandler` 独占，本 handler 一律不碰。
public final class RelayConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    private let rooms: RelayRooms
    private let limiter: RelayLimiter            // 房间配额（连接配额归 ConnectionCountHandler）
    private let sessionId: String
    private let role: RelayPeer
    private var accumulator: FrameAccumulator   // 单消息字节上限累积器（4.1）
    private var connId: UUID?                    // 本连接的唯一身份（3.4，D4）
    private var admittedRoom = false             // 本连接是否已计入房间配额

    public init(rooms: RelayRooms, limiter: RelayLimiter,
                sessionId: String, role: RelayPeer, maxMessageBytes: Int) {
        self.rooms = rooms
        self.limiter = limiter
        self.sessionId = sessionId
        self.role = role
        self.accumulator = FrameAccumulator(maxBytes: maxMessageBytes)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        // 房间总数配额:超上限拒(fail-closed)。连接计数不在此处理——归 ConnectionCountHandler（D1）。
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

    public func handlerRemoved(context: ChannelHandlerContext) {
        // 仅按本连接自己的 connId 精确 leave;被拒连接(connId 为 nil)不误清占用槽的先到连接。
        if let id = connId {
            rooms.leave(sessionId: sessionId, role: role, connId: id)
        }
        // 房间用引用计数,每次成功 admitRoom 对应一次 releaseRoom,房间仅在最后一端离开才释放。
        if admittedRoom { limiter.releaseRoom(sessionId: sessionId) }
        // 连接计数不在此释放——归 ConnectionCountHandler（D1）。
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)   // 空闲超时:回收连接释放资源(4.2)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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
/// 遵循 RemovableChannelHandler：ws upgrade 成功后本 handler 会被移出管线（否则 ws 帧强转
/// HTTP 类型崩溃）；removeHandler 仅接受可移除 handler，故必须显式声明该协议（默认实现即可）。
public final class HealthHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private var keepAlive = false

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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
