import Foundation

public final class BridgeOutputRouter: @unchecked Sendable {
    public struct Attachment: Sendable, Equatable {
        fileprivate let id: UUID
    }

    public typealias Sink = @Sendable (String) -> Void

    private let stream: @Sendable () -> AsyncStream<String>
    private let onBridgeExit: @Sendable () -> Void
    private let lock = NSLock()

    private var active: (attachment: Attachment, sink: Sink)?
    private var task: Task<Void, Never>?
    private var stopping = false
    private var finished = false

    public init(
        stream: @escaping @Sendable () -> AsyncStream<String>,
        onBridgeExit: @escaping @Sendable () -> Void
    ) {
        self.stream = stream
        self.onBridgeExit = onBridgeExit
    }

    public func start() {
        lock.lock()
        guard task == nil, !stopping, !finished else {
            lock.unlock()
            return
        }
        let stream = self.stream()
        task = Task { [weak self] in
            for await line in stream {
                self?.route(line)
            }
            self?.streamFinished()
        }
        lock.unlock()
    }

    @discardableResult
    public func attach(_ sink: @escaping Sink) -> Attachment {
        let attachment = Attachment(id: UUID())
        lock.lock()
        active = (attachment, sink)
        lock.unlock()
        return attachment
    }

    public func detach(_ attachment: Attachment) {
        lock.lock()
        if active?.attachment == attachment { active = nil }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopping = true
        active = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    func route(_ line: String) {
        lock.lock()
        let sink = active?.sink
        lock.unlock()
        sink?(line)
    }

    private func streamFinished() {
        lock.lock()
        let shouldReport = !stopping
        finished = true
        task = nil
        lock.unlock()
        if shouldReport { onBridgeExit() }
    }
}
