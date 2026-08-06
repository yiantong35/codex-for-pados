import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RelayProtocol
@testable import RelayDialoutCore

private final class LargeFrameReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let expected: String
    private let received: XCTestExpectation

    init(expected: String, received: XCTestExpectation) {
        self.expected = expected
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        if let maskKey = frame.maskKey { frame.data.webSocketUnmask(maskKey) }
        if frame.data.readString(length: frame.data.readableBytes) == expected {
            received.fulfill()
        }
    }
}

private final class LargeFrameSender: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let payload: String

    init(payload: String) { self.payload = payload }

    func handlerAdded(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: payload.utf8.count)
        buffer.writeString(payload)
        context.writeAndFlush(
            wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)),
            promise: nil
        )
    }
}

private final class UpgradeRequestWriter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
            .withHeaders(headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

private extension HTTPRequestHead {
    func withHeaders(_ headers: HTTPHeaders) -> HTTPRequestHead {
        var copy = self
        copy.headers = headers
        return copy
    }
}

final class LargeFrameIntegrationTests: XCTestCase {
    func testProductionClientUpgraderReceivesFrameAboveNIODefault() throws {
        let payload = String(repeating: "x", count: 64 * 1024)
        XCTAssertGreaterThan(payload.utf8.count, 1 << 14)
        XCTAssertLessThan(payload.utf8.count, RelayWireLimits.maxMessageBytes)

        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var serverChannel: Channel?
        var clientChannel: Channel?
        defer {
            try? clientChannel?.close().wait()
            try? serverChannel?.close().wait()
            try? clientGroup.syncShutdownGracefully()
            try? serverGroup.syncShutdownGracefully()
        }

        let serverUpgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: RelayWireLimits.maxMessageBytes,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(LargeFrameSender(payload: payload))
            }
        )
        serverChannel = try ServerBootstrap(group: serverGroup)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [serverUpgrader], completionHandler: { _ in })
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let port = try XCTUnwrap(serverChannel?.localAddress?.port)

        let received = expectation(description: "64 KiB WebSocket frame received")
        let requestWriter = UpgradeRequestWriter()
        let clientUpgrader = DialoutWebSocket.makeClientUpgrader { channel, _ in
            channel.pipeline.addHandler(LargeFrameReceiver(expected: payload, received: received))
        }
        let config = NIOHTTPClientUpgradeConfiguration(
            upgraders: [clientUpgrader],
            completionHandler: { channel in
                channel.pipeline.removeHandler(requestWriter, promise: nil)
            }
        )
        clientChannel = try ClientBootstrap(group: clientGroup)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
                    .flatMap { channel.pipeline.addHandler(requestWriter) }
            }
            .connect(host: "127.0.0.1", port: port)
            .wait()

        wait(for: [received], timeout: 10)
    }
}
