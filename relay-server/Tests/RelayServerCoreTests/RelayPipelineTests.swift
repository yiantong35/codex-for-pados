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

// MARK: - Task 3 边界：ConnectionCountHandler 全局计数所有权（D1 主路径）

/// /health（非 upgrade）连接从建立即计入全局配额；关闭后释放（计数所有权对称）。
@Test func healthConnectionCountsAndReleases() throws {
    let limiter = RelayLimiter(maxTotalConnections: 1, maxRooms: 10)
    let channel = EmbeddedChannel()
    try configureRelayPipeline(channel: channel, rooms: RelayRooms(), limiter: limiter).wait()
    try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/h1")).wait()
    // channelActive → ConnectionCountHandler 计数：占 1 格。
    #expect(limiter.activeConnectionsSnapshot == 1, "建连即计入全局配额")
    _ = try? channel.finish()                        // 关闭 → channelInactive → releaseConnection
    #expect(limiter.activeConnectionsSnapshot == 0, "关闭后释放全局配额")
}

/// 超全局配额的新连接：channelActive 即被拒关闭；从未 admit 成功者关闭时不误减。
@Test func overQuotaConnectionRejectedAndNoFalseRelease() throws {
    let limiter = RelayLimiter(maxTotalConnections: 1, maxRooms: 10)
    #expect(limiter.admitConnection())               // 先把唯一配额占满（模拟已有连接）
    #expect(limiter.activeConnectionsSnapshot == 1)
    let channel = EmbeddedChannel()
    try configureRelayPipeline(channel: channel, rooms: RelayRooms(), limiter: limiter).wait()
    try? channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/h2")).wait()
    #expect(channel.isActive == false, "超配额 → ConnectionCountHandler 关连接")
    _ = try? channel.finish()
    // 被拒连接（admitted=false）关闭时不得 releaseConnection，否则把先前那条的配额凭空释放。
    #expect(limiter.activeConnectionsSnapshot == 1, "被拒连接关闭时不误减先前连接的配额")
}

/// upgrade 成功后不对同一连接双计：走完 ws upgrade，全局计数应恰为 1。
@Test func upgradeDoesNotDoubleCount() throws {
    let loop = EmbeddedEventLoop()
    let channel = EmbeddedChannel(loop: loop)
    let limiter = RelayLimiter(maxTotalConnections: 5, maxRooms: 10)
    try configureRelayPipeline(channel: channel, rooms: RelayRooms(), limiter: limiter).wait()
    try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/h3")).wait()
    #expect(limiter.activeConnectionsSnapshot == 1, "connect 后 HEAD-ward 计数 1")
    let req = "GET /relay/s HTTP/1.1\r\nHost: x\r\nx-role: iPad\r\nConnection: upgrade\r\n" +
              "Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n" +
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    var buf = channel.allocator.buffer(capacity: req.utf8.count); buf.writeString(req)
    try channel.writeInbound(buf)
    // 关键：EmbeddedChannel 上 upgrade 异步排到 loop，必须驱动才真正完成。
    loop.run()
    // 计数所有权唯一在 ConnectionCountHandler：upgrade 后 RelayConnectionHandler 不再计数 → 仍恰为 1。
    #expect(limiter.activeConnectionsSnapshot == 1, "upgrade 后不双计，全局计数恒为 1")
    _ = try? channel.finish()
    #expect(limiter.activeConnectionsSnapshot == 0, "关闭后释放，计数归 0")
}

/// 慢 upgrade / 只连不发：pre-upgrade 连接受空闲超时回收（HEAD-ward IdleState 兜底）。
///
/// 说明（NIO 实证）：`IdleStateHandler` 的超时判定用 `NIODeadline.now()`（**真实墙钟**）计算
/// `diff = now - lastActivity`，而 `EmbeddedEventLoop.advanceTime` 只推进**虚拟时钟**——两者脱钩，
/// 故 `advanceTime` 触发不了 idle 事件（NIO 自身的 IdleStateHandler 测试用真实 MTELG 而非 EmbeddedChannel
/// 正是此因）。因此本测试拆成两条确定性断言，覆盖 Task 3 真正新增的“HEAD-ward idle→close 兜底”契约：
///   (1) `IdleStateHandler` 确已装在管线（HEAD-ward，覆盖 upgrade 前的慢连接）；
///   (2) 一旦 idle 事件到达（等价于 IdleStateHandler 判超时后 fire 的事件），`ConnectionCountHandler`
///       兜底关连接并释放全局配额（upgrade 前尚无 RelayConnectionHandler 消费该事件）。
/// IdleStateHandler 自身的墙钟计时属 NIO 组件职责，不在此重复验证；真实公网空闲回收由 Task 10 真机验收。
@Test func idleEventClosesPreUpgradeConnectionAndReleases() throws {
    let limiter = RelayLimiter(maxTotalConnections: 5, maxRooms: 10)
    let channel = EmbeddedChannel()
    try configureRelayPipeline(channel: channel, rooms: RelayRooms(), limiter: limiter,
                               idleTimeoutSeconds: 1).wait()
    try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/idle")).wait()
    #expect(limiter.activeConnectionsSnapshot == 1)
    // (1) IdleStateHandler HEAD-ward 已安装（handler(type:) 找不到会抛错）。
    _ = try channel.pipeline.handler(type: IdleStateHandler.self).wait()
    // (2) 注入 idle 事件（自管线头 fire，向尾部流经 IdleStateHandler → ConnectionCountHandler 兜底消费）。
    channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.all)
    #expect(channel.isActive == false, "idle 事件应触发 HEAD-ward 兜底关连接")
    #expect(limiter.activeConnectionsSnapshot == 0, "关连接后释放全局配额（channelInactive 对称释放）")
}
