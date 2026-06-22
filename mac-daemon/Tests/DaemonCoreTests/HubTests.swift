import XCTest
import Foundation
@testable import DaemonCore

/// 线程安全收集器:sink 在 Hub actor 方法内同步执行,方法 await 返回后即可断言。
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    func add(_ d: Data) { lock.lock(); items.append(d); lock.unlock() }
    func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all().count }
}

final class HubTests: XCTestCase {
    private func jv(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }
    private func env(_ d: Data) -> Envelope {
        try! Envelope.decode(from: d)
    }

    /// 一端 ingest,所有下游都收到同一条 event(seq + payload 一致)= 同步广播。
    func testBroadcastToAllDownstreams() async {
        let a = Box(); let b = Box()
        let hub = Hub(sendToAppServer: { _ in })
        await hub.addDownstream(id: UUID(), sink: { [a] d in a.add(d) })
        await hub.addDownstream(id: UUID(), sink: { [b] d in b.add(d) })

        await hub.ingestFromAppServer(Data(#"{"method":"turn/started"}"#.utf8))

        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        guard case let .event(seqA, payloadA) = env(a.all()[0]),
              case let .event(seqB, payloadB) = env(b.all()[0]) else {
            return XCTFail("both downstreams should receive an event frame")
        }
        XCTAssertEqual(seqA, 1)
        XCTAssertEqual(seqB, 1)
        XCTAssertEqual(payloadA, jv(#"{"method":"turn/started"}"#))
        XCTAssertEqual(payloadA, payloadB)
    }

    /// 下游 request 帧 → 内层 JSON-RPC payload 透传给 app-server。
    func testRequestForwardedToAppServer() async {
        let sent = Box()
        let hub = Hub(sendToAppServer: { [sent] d in sent.add(d) })
        let id = UUID()
        await hub.addDownstream(id: id, sink: { _ in })

        let frame = try! Envelope.request(payload: jv(#"{"id":1,"method":"turn/start"}"#)).encode()
        await hub.handleDownstream(frame, from: id)

        XCTAssertEqual(sent.count, 1)
        // 透传出去的应是内层 JSON-RPC,解析回 JSONValue 应相等
        let forwarded = try! JSONDecoder().decode(JSONValue.self, from: sent.all()[0])
        XCTAssertEqual(forwarded, jv(#"{"id":1,"method":"turn/start"}"#))
    }

    /// resync 命中:补发 after 之后、仍在缓冲内的 event。
    func testResyncReplaysMissed() async {
        let a = Box()
        let hub = Hub(sendToAppServer: { _ in })
        let id = UUID()
        await hub.addDownstream(id: id, sink: { [a] d in a.add(d) })

        await hub.ingestFromAppServer(Data(#"{"n":1}"#.utf8))   // seq1
        await hub.ingestFromAppServer(Data(#"{"n":2}"#.utf8))   // seq2
        await hub.ingestFromAppServer(Data(#"{"n":3}"#.utf8))   // seq3
        let before = a.count

        await hub.handleDownstream(try! Envelope.resync(after: 1).encode(), from: id)

        let replayed = a.all().suffix(a.count - before).map { env($0) }
        let seqs = replayed.compactMap { e -> UInt64? in
            if case let .event(seq, _) = e { return seq }; return nil
        }
        XCTAssertEqual(seqs, [2, 3])
    }

    /// resync 缺口(请求的 seq 已被环形缓冲淘汰)→ snapshot-needed。
    func testResyncGapYieldsSnapshotNeeded() async {
        let a = Box()
        let hub = Hub(capacity: 2, sendToAppServer: { _ in })
        let id = UUID()
        await hub.addDownstream(id: id, sink: { [a] d in a.add(d) })

        // 灌 3 条,capacity=2 → seq1 被淘汰
        await hub.ingestFromAppServer(Data(#"{"n":1}"#.utf8))
        await hub.ingestFromAppServer(Data(#"{"n":2}"#.utf8))
        await hub.ingestFromAppServer(Data(#"{"n":3}"#.utf8))
        let before = a.count

        await hub.handleDownstream(try! Envelope.resync(after: 0).encode(), from: id)

        let news = a.all().suffix(a.count - before).map { env($0) }
        XCTAssertTrue(news.contains(.snapshotNeeded), "gap should yield snapshot-needed")
    }

    /// 移除下游后不再收到广播。
    func testRemovedDownstreamStopsReceiving() async {
        let a = Box()
        let hub = Hub(sendToAppServer: { _ in })
        let id = UUID()
        await hub.addDownstream(id: id, sink: { [a] d in a.add(d) })
        await hub.removeDownstream(id: id)

        await hub.ingestFromAppServer(Data(#"{"n":1}"#.utf8))
        XCTAssertEqual(a.count, 0)
    }
}
