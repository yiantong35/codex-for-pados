import Testing
import Foundation
import NIOCore
import NIOPosix
@testable import RelayServerCore

/// F3 真钟集成测：以**真实 NIO 服务 + 真墙钟**验证「握手期短空闲」与「已升级 WS 长空闲」两段解耦。
///
/// 为什么必须真钟（上轮教训，回归锚）：`IdleStateHandler` 的超时判定用 `NIODeadline.now()`（真实墙钟），
/// 与 `EmbeddedEventLoop.advanceTime`（虚拟时钟）**脱钩**——EmbeddedChannel 上 `advanceTime` 触发不了
/// idle 事件，会假绿。故本文件启一条真 `ServerBootstrap`（loopback 随机端口），注入**短窗口值**
/// （短空闲 1s / 升级后长窗口 4s），用真 `Task.sleep` 等待，观察真实关连接行为。
/// RelayPipelineTests.upgradeSwapsShortIdleForLongWindow 从**接线**角度证明替换发生；本测从
/// **真实计时**角度证明两段窗口各自生效，两者互补。

/// 线程安全的「已关闭」闩（URLSession 回调 / NIO 客户端回调可能在别的线程置位）。
private final class ClosedLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func mark() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/// 启一条真 relay 服务（loopback 随机端口），返回服务 channel / group / 端口。
private func startRelayServer(idleTimeoutSeconds: Int64,
                              upgradedIdleTimeoutSeconds: Int64) throws
    -> (channel: Channel, group: EventLoopGroup, port: Int) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let rooms = RelayRooms()
    let limiter = RelayLimiter(maxTotalConnections: 100, maxRooms: 100)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            configureRelayPipeline(channel: channel, rooms: rooms, limiter: limiter,
                                   idleTimeoutSeconds: idleTimeoutSeconds,
                                   upgradedIdleTimeoutSeconds: upgradedIdleTimeoutSeconds)
        }
    let serverChannel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    guard let port = serverChannel.localAddress?.port else {
        try? group.syncShutdownGracefully()
        throw RelayError.badUpgrade
    }
    return (serverChannel, group, port)
}

/// 同步收尾（从非 async 函数调用 syncShutdownGracefully，规避「async 上下文不可用」限制）。
private func teardown(_ channel: Channel, _ group: EventLoopGroup) {
    try? channel.close().wait()
    try? group.syncShutdownGracefully()
}
private func teardown(_ group: EventLoopGroup) {
    try? group.syncShutdownGracefully()
}
private func closeChannel(_ channel: Channel) {
    try? channel.close().wait()
}

/// 记录客户端 channel 何时被服务端关闭（channelInactive）。
private final class InactiveProbe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let latch: ClosedLatch
    init(_ latch: ClosedLatch) { self.latch = latch }
    func channelInactive(context: ChannelHandlerContext) {
        latch.mark()
        context.fireChannelInactive()
    }
}

/// (A) 已升级健康 WS：越过握手期短空闲（1s）仍存活（证明短窗口未作用于已升级连接），
///     继续静默越过长窗口（4s）后被兜底回收（证明长窗口仍兜底、无僵尸长存）。
@Test func upgradedWSSurvivesShortIdleThenReclaimedByLongWindow() async throws {
    let server = try startRelayServer(idleTimeoutSeconds: 1, upgradedIdleTimeoutSeconds: 4)
    defer { teardown(server.channel, server.group) }

    var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/relay/f3-live")!)
    req.setValue("iPad", forHTTPHeaderField: "x-role")
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: req)

    // receive 在连接被服务端关闭时以 failure 完成——用它作为「已被回收」信号（不产生出站活动）。
    let closed = ClosedLatch()
    task.resume()
    task.receive { result in
        if case .failure = result { closed.mark() }
    }

    // 等 upgrade 落定（最后一次活动 ≈ 此刻）。
    try await Task.sleep(nanoseconds: 500_000_000)

    // t ≈ 2s 空闲：若握手期短空闲(1s)仍作用于已升级连接，此刻应已被回收；断言仍存活。
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(closed.isClosed == false, "已升级 WS 越过握手期短空闲(1s)不应被回收（两段解耦）")

    // 继续静默越过长窗口(4s)：断言最终被兜底回收（轮询至多 ~12s），证明无无限存活僵尸。
    var reclaimed = false
    for _ in 0..<48 {
        try await Task.sleep(nanoseconds: 250_000_000)
        if closed.isClosed { reclaimed = true; break }
    }
    #expect(reclaimed == true, "已升级 WS 越过长空闲窗口(4s)后应被兜底回收（无僵尸）")
    task.cancel(with: .goingAway, reason: nil)
}

/// (B) upgrade 之前只连不发的慢连接：受握手期短空闲(1s)回收。真 TCP 客户端连上不发任何数据，
///     断言 ~短窗口后被服务端关闭（channelInactive）。
@Test func preUpgradeIdleConnectionReclaimedByShortWindow() async throws {
    let server = try startRelayServer(idleTimeoutSeconds: 1, upgradedIdleTimeoutSeconds: 4)
    defer { teardown(server.channel, server.group) }

    let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { teardown(clientGroup) }

    let closed = ClosedLatch()
    let client = try ClientBootstrap(group: clientGroup)
        .channelInitializer { ch in ch.pipeline.addHandler(InactiveProbe(closed)) }
        .connect(host: "127.0.0.1", port: server.port).wait()
    defer { closeChannel(client) }

    // 不发送任何数据（只连不发）：服务端应在握手期短空闲(1s)后关连接。轮询至多 ~6s。
    var reclaimed = false
    for _ in 0..<24 {
        try await Task.sleep(nanoseconds: 250_000_000)
        if closed.isClosed { reclaimed = true; break }
    }
    #expect(reclaimed == true, "upgrade 前只连不发的连接应被握手期短空闲(1s)回收")
}
