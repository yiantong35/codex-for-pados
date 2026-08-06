import Testing
import NIOCore
import NIOPosix
@testable import RelayDialoutCore

private final class CloseAfterAccept: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

private actor ReconnectCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

private func startClosingServer() throws -> (Channel, EventLoopGroup, Int) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(CloseAfterAccept())
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    return (channel, group, channel.localAddress!.port!)
}

private func stopClosingServer(_ channel: Channel, _ group: EventLoopGroup) {
    try? channel.close().wait()
    try? group.syncShutdownGracefully()
}

private func stopClosingGroup(_ group: EventLoopGroup) {
    try? group.syncShutdownGracefully()
}

@Test func supervisorReconnectsAfterRealRemoteClose() async throws {
    let server = try startClosingServer()
    defer { stopClosingServer(server.0, server.1) }
    let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { stopClosingGroup(clientGroup) }
    let attempts = ReconnectCounter()

    let supervisor = DialoutSupervisor(
        policy: .init(baseDelayNanoseconds: 1, maxDelayNanoseconds: 4, jitterFraction: 0),
        connector: {
            let number = await attempts.next()
            let channel = try await ClientBootstrap(group: clientGroup)
                .connect(host: "127.0.0.1", port: server.2)
                .get()
            try await channel.closeFuture.get()
            return number == 3
                ? .terminal(.trustRejected)
                : .closed(wasHealthy: false)
        },
        sleep: { _ in },
        onShutdown: {}
    )

    #expect(await supervisor.run() == .trustRejected)
    #expect(await attempts.value == 3)
}
