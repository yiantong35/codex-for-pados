import Foundation

/// 广播中心(actor):唯一真相源的扇出与回流路由。
///
/// - `ingestFromAppServer`:app-server 每条输出 → seq++ 入缓冲 → 封 event 帧 fan-out 给所有下游。
/// - `addDownstream` / `removeDownstream`:管理下游连接(每个一个 sink 闭包,发 WS 文本帧)。
/// - `handleDownstream`:下游帧路由 —— `request` 透传 app-server stdin;`resync` 用 SeqBuffer 补发,
///   缺口则回 `snapshot-needed`。
///
/// 由此实现"一端发起、多端实时同步"(广播)与"两端收发"(回流)。
public actor Hub {
    /// 向某个下游发送一帧(WS 文本帧的编码后字节)。
    public typealias Sink = @Sendable (Data) -> Void
    /// 把下游请求的内层 JSON-RPC 透传给 app-server。
    public typealias AppServerSend = @Sendable (Data) -> Void

    private var buffer: SeqBuffer
    private var downstreams: [UUID: Sink] = [:]
    private let sendToAppServer: AppServerSend

    public init(capacity: Int = 1000, sendToAppServer: @escaping AppServerSend) {
        self.buffer = SeqBuffer(capacity: capacity)
        self.sendToAppServer = sendToAppServer
    }

    public func addDownstream(id: UUID, sink: @escaping Sink) {
        downstreams[id] = sink
    }

    public func removeDownstream(id: UUID) {
        downstreams[id] = nil
    }

    public var downstreamCount: Int { downstreams.count }

    /// app-server 的一条输出:分配 seq、入缓冲、封 event 帧广播给所有下游。
    public func ingestFromAppServer(_ payload: Data) {
        let (_, event) = buffer.append(payload)
        guard let frame = try? Envelope.event(from: event).encode() else { return }
        for sink in downstreams.values {
            sink(frame)
        }
    }

    /// 处理下游发来的一帧。
    public func handleDownstream(_ frame: Data, from id: UUID) {
        guard let envelope = try? Envelope.decode(from: frame) else { return }
        switch envelope {
        case let .request(payload):
            // 内层 JSON-RPC 透传给 app-server。
            if let data = try? JSONEncoder().encode(payload) {
                sendToAppServer(data)
            }
        case let .resync(after):
            resync(after: after, to: id)
        case .event, .snapshotNeeded:
            // 下游不应发这两类;忽略。
            break
        }
    }

    // MARK: - 内部

    private func resync(after: UInt64, to id: UUID) {
        guard let sink = downstreams[id] else { return }
        if let missed = buffer.replay(after: after) {
            for event in missed {
                if let frame = try? Envelope.event(from: event).encode() {
                    sink(frame)
                }
            }
        } else {
            // 缺口超出缓冲:提示全量快照。
            if let frame = try? Envelope.snapshotNeeded.encode() {
                sink(frame)
            }
        }
    }
}
