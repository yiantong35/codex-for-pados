import Testing
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
@testable import RelayServerCore

/// D1 实证结论（Task 1 探针，实测 swift-nio 2.65 / arm64e-macos）：
///   HEAD-ward handler **穿越 WebSocket upgrade 存活，且仍收 channelInactive**。
///   => Task 3/4 采用**主装配**：单个 ConnectionCountHandler 装在 configureHTTPServerPipeline
///      之前（管线头），独占整条连接的全局并发计数（channelActive 计数 / channelInactive 释放），
///      无需 pre/post 分别计数的退路。
///
///   实测关键细节（回归锚必须复现，否则测试会“假绿”）：
///   在 EmbeddedChannel 上，HTTP→WS upgrade **不是** writeInbound 同步完成的，而是排到 event loop
///   上异步执行——必须显式 `loop.run()` 驱动，upgrade 才真正发生（upgradePipelineHandler 才跑、
///   HTTP handler 才被替换）。若不驱动 loop 就直接断言 active/inactive，探针只是拿到了 connect/close
///   的生命周期回调，**并未真正经历一次 upgrade**（假绿）。故本测试显式驱动 upgrade 完成
///   （断言 box.upgraded == true）后，再关闭连接断言 box.inactive == true，才真正证明
///   “HEAD-ward 存活穿越了一次 *已完成* 的 upgrade”。

/// 只记录 channelActive/channelInactive 是否触达、以及 upgrade 是否完成的探针 handler（不做业务）。
private final class LifecycleProbe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    final class Box: @unchecked Sendable {
        var active = false
        var inactive = false
        var upgraded = false
    }
    let box: Box
    init(_ box: Box) { self.box = box }
    func channelActive(context: ChannelHandlerContext) { box.active = true; context.fireChannelActive() }
    func channelInactive(context: ChannelHandlerContext) { box.inactive = true; context.fireChannelInactive() }
}

@Test func headwardHandlerSurvivesWebSocketUpgrade() throws {
    let loop = EmbeddedEventLoop()
    let channel = EmbeddedChannel(loop: loop)
    let box = LifecycleProbe.Box()
    // HEAD-ward：先装 probe（位于管线头），再装 HTTP upgrade 管线。
    try channel.pipeline.addHandler(LifecycleProbe(box)).wait()
    let upgrader = NIOWebSocketServerUpgrader(
        maxFrameSize: 1 << 20,
        shouldUpgrade: { ch, _ in ch.eventLoop.makeSucceededFuture(HTTPHeaders()) },
        // upgrade 真正完成时才会跑到这里——用它作为“upgrade 已发生”的实证信号。
        upgradePipelineHandler: { ch, _ in box.upgraded = true; return ch.eventLoop.makeSucceededFuture(()) })
    try channel.pipeline.configureHTTPServerPipeline(
        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })).wait()
    try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/probe")).wait()
    #expect(box.active == true, "connect 后 HEAD-ward 应收 channelActive")

    // 驱动一次最小 WebSocket upgrade 请求。
    let req = "GET /relay/s HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n" +
              "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    var buf = channel.allocator.buffer(capacity: req.utf8.count)
    buf.writeString(req)
    try channel.writeInbound(buf)

    // 关键：EmbeddedChannel 上 upgrade 异步排到 loop，必须驱动才真正完成。
    loop.run()
    #expect(box.upgraded == true, "upgrade 必须真正完成（否则下方存活断言为假绿）")

    // upgrade 完成后关闭连接，观察 HEAD-ward probe 是否仍收 channelInactive。
    _ = try? channel.finish()
    #expect(box.inactive == true, "HEAD-ward handler 应穿越 upgrade 存活并收 channelInactive")
}
