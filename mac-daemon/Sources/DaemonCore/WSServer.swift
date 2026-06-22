import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// 局域网 WebSocket server(SwiftNIO):
/// - HTTP upgrade 时校验预共享 token(query 参数),失败拒绝 upgrade。
/// - 每个 WS 连接 = 一个下游:连上注册到 Hub,收到文本帧转 Hub.handleDownstream,
///   Hub 广播来的帧编码为 WS 文本帧写回。
///
/// 集成行为(真实多端同步)由 Task 8 验证。
public final class WSServer {
    private let host: String
    private let port: Int
    private let token: String
    private let hub: Hub
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(host: String = "0.0.0.0", port: Int, token: String, hub: Hub) {
        self.host = host
        self.port = port
        self.token = token
        self.hub = hub
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// 启动监听,返回绑定后的本地地址。
    @discardableResult
    public func start() throws -> SocketAddress {
        let token = self.token
        let hub = self.hub

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { (channel, head) -> EventLoopFuture<HTTPHeaders?> in
                        // token 校验:不通过返回 nil 拒绝 upgrade。
                        if TokenAuth.authorize(uri: head.uri, expected: token) {
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        } else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                    },
                    upgradePipelineHandler: { (channel, _) -> EventLoopFuture<Void> in
                        channel.pipeline.addHandler(DownstreamHandler(hub: hub))
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }

        let ch = try bootstrap.bind(host: host, port: port).wait()
        self.channel = ch
        return ch.localAddress!
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// 单个 WS 下游连接的 channel handler。把连接接入 Hub,双向桥接帧。
final class DownstreamHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: Hub
    private let id = UUID()
    private var textBuffer = ByteBuffer()

    init(hub: Hub) {
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // 注册下游:sink 把 Hub 广播的字节编成 WS 文本帧写回本连接。
        let channel = context.channel
        let hub = self.hub
        let id = self.id
        let sink: Hub.Sink = { data in
            channel.eventLoop.execute {
                var buf = channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(NIOAny(frame), promise: nil)
            }
        }
        Task { await hub.addDownstream(id: id, sink: sink) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        let hub = self.hub
        let id = self.id
        Task { await hub.removeDownstream(id: id) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .continuation:
            textBuffer.writeImmutableBuffer(frame.unmaskedData)
            if frame.fin {
                let bytes = textBuffer.readBytes(length: textBuffer.readableBytes) ?? []
                textBuffer.clear()
                let payload = Data(bytes)
                let hub = self.hub
                let id = self.id
                Task { await hub.handleDownstream(payload, from: id) }
            }
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            var frameData = frame.data
            let maskingKey = frame.maskKey
            if let key = maskingKey { frameData.webSocketUnmask(key) }
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }
}
