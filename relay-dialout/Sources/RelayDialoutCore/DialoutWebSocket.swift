import NIOCore
import NIOHTTP1
import NIOWebSocket
import RelayProtocol

public enum DialoutWebSocket {
    public static func makeClientUpgrader(
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    ) -> NIOWebSocketClientUpgrader {
        NIOWebSocketClientUpgrader(
            maxFrameSize: RelayWireLimits.maxMessageBytes,
            upgradePipelineHandler: upgradePipelineHandler
        )
    }
}
