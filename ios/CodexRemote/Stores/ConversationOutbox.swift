import Foundation
import Observation

struct PendingConversationMessage {
    let input: [UserInput]
    let model: String?
    let effort: ReasoningEffort?
    let clientId: String
    let byteCount: Int

    var localId: String { "local-\(clientId)" }
}

struct ConversationOutboxLimits {
    /// Leaves room for JSON-RPC and the base64-encoded E2E envelope inside the 1 MiB relay frame.
    var maxBytesPerMessage = 740 * 1_024
    var maxMessagesPerThread = 32
    var maxBytesPerThread = 4 * 1_024 * 1_024
    var maxMessagesPerSession = 128
    var maxBytesPerSession = 12 * 1_024 * 1_024
}

enum ConversationOutboxError: LocalizedError, Equatable {
    case messageTooLarge
    case threadLimit
    case sessionLimit

    var errorDescription: String? {
        switch self {
        case .messageTooLarge:
            return "This message is too large to send. Shorten the text or remove the image and try again."
        case .threadLimit:
            return "This conversation's offline queue is full. Reconnect or remove a queued message before sending more."
        case .sessionLimit:
            return "This session's offline queue is full. Reconnect or clear another conversation before sending more."
        }
    }
}

@MainActor
fileprivate final class ConversationOutboxBudget {
    private(set) var messageCount = 0
    private(set) var byteCount = 0
    let limits: ConversationOutboxLimits

    init(limits: ConversationOutboxLimits) {
        self.limits = limits
    }

    func reserve(bytes: Int) throws {
        guard bytes <= limits.maxBytesPerSession,
              messageCount < limits.maxMessagesPerSession,
              byteCount <= limits.maxBytesPerSession - bytes else {
            throw ConversationOutboxError.sessionLimit
        }
        messageCount += 1
        byteCount += bytes
    }

    func release(messages: Int, bytes: Int) {
        messageCount = max(0, messageCount - messages)
        byteCount = max(0, byteCount - bytes)
    }
}

/// Thread-scoped outbound state. Session owners retain this object across view and RPC rebuilds.
@Observable
@MainActor
final class ConversationOutbox {
    private(set) var entries: [PendingConversationMessage] = []
    private var sendingClientId: String?
    private var rpcIdentity: ObjectIdentifier?
    @ObservationIgnored private let budget: ConversationOutboxBudget
    @ObservationIgnored private let limits: ConversationOutboxLimits

    init(limits: ConversationOutboxLimits = ConversationOutboxLimits()) {
        self.limits = limits
        self.budget = ConversationOutboxBudget(limits: limits)
    }

    fileprivate init(limits: ConversationOutboxLimits, budget: ConversationOutboxBudget) {
        self.limits = limits
        self.budget = budget
    }

    var queuedEntries: [PendingConversationMessage] {
        entries.filter { $0.clientId != sendingClientId }
    }

    var totalByteCount: Int { entries.reduce(0) { $0 + $1.byteCount } }

    func attach(to rpc: JSONRPCClient) {
        let identity = ObjectIdentifier(rpc)
        if let rpcIdentity, rpcIdentity != identity {
            sendingClientId = nil
        }
        rpcIdentity = identity
    }

    func enqueue(input: [UserInput], model: String?, effort: ReasoningEffort?) throws
        -> PendingConversationMessage {
        let byteCount = Self.estimatedByteCount(input: input, model: model)
        guard byteCount <= limits.maxBytesPerMessage else {
            throw ConversationOutboxError.messageTooLarge
        }
        let encodedInputBytes = (try? JSONEncoder().encode(input).count) ?? Int.max
        guard encodedInputBytes <= limits.maxBytesPerMessage - 4_096 else {
            throw ConversationOutboxError.messageTooLarge
        }
        guard byteCount <= limits.maxBytesPerThread,
              entries.count < limits.maxMessagesPerThread,
              totalByteCount <= limits.maxBytesPerThread - byteCount else {
            throw ConversationOutboxError.threadLimit
        }
        try budget.reserve(bytes: byteCount)
        let entry = PendingConversationMessage(
            input: input,
            model: model,
            effort: effort,
            clientId: UUID().uuidString,
            byteCount: byteCount
        )
        entries.append(entry)
        return entry
    }

    private static func estimatedByteCount(input: [UserInput], model: String?) -> Int {
        var total = (model?.utf8.count ?? 0) + 128
        for value in input {
            let payloadBytes: Int
            switch value {
            case .text(let text): payloadBytes = text.utf8.count
            case .image(let url, _): payloadBytes = url.utf8.count
            case .localImage(let path, _): payloadBytes = path.utf8.count
            }
            let (payloadWithOverhead, overheadOverflow) = payloadBytes.addingReportingOverflow(32)
            guard !overheadOverflow else { return Int.max }
            let (next, overflow) = total.addingReportingOverflow(payloadWithOverhead)
            guard !overflow else { return Int.max }
            total = next
        }
        return total
    }

    func beginSending() -> PendingConversationMessage? {
        guard sendingClientId == nil, let entry = entries.first else { return nil }
        sendingClientId = entry.clientId
        return entry
    }

    /// An authoritative userMessage echo proves acceptance, but the RPC may still be in flight.
    func acknowledge(clientId: String) {
        removeEntry(clientId: clientId)
    }

    /// RPC success acknowledges the entry; completion or authoritative resume opens the next window.
    func finishSending(clientId: String) {
        removeEntry(clientId: clientId)
    }

    /// A completion may open the next window only after this client's entry was accepted.
    /// If the entry is still present, the event can belong to another client and is ignored.
    func releaseAcceptedSendingWindow() {
        guard let sendingClientId,
              !entries.contains(where: { $0.clientId == sendingClientId }) else { return }
        self.sendingClientId = nil
    }

    @discardableResult
    func discard(clientId: String) -> PendingConversationMessage? {
        let entry = entries.first { $0.clientId == clientId }
        removeEntry(clientId: clientId)
        if sendingClientId == clientId { sendingClientId = nil }
        return entry
    }

    @discardableResult
    func failSending(clientId: String) -> Bool {
        let remainsPending = entries.contains { $0.clientId == clientId }
        if sendingClientId == clientId { sendingClientId = nil }
        return remainsPending
    }

    func reconcileAuthoritativeState() {
        sendingClientId = nil
    }

    func removeAll() {
        let bytes = totalByteCount
        let count = entries.count
        entries.removeAll()
        sendingClientId = nil
        budget.release(messages: count, bytes: bytes)
    }

    private func removeEntry(clientId: String) {
        guard let index = entries.firstIndex(where: { $0.clientId == clientId }) else { return }
        let entry = entries.remove(at: index)
        budget.release(messages: 1, bytes: entry.byteCount)
    }
}

@Observable
@MainActor
final class ConversationOutboxRegistry {
    private var outboxes: [String: ConversationOutbox] = [:]
    @ObservationIgnored private let limits: ConversationOutboxLimits
    @ObservationIgnored private let budget: ConversationOutboxBudget

    init(limits: ConversationOutboxLimits = ConversationOutboxLimits()) {
        self.limits = limits
        self.budget = ConversationOutboxBudget(limits: limits)
    }

    func outbox(for threadId: String) -> ConversationOutbox {
        if let existing = outboxes[threadId] { return existing }
        let created = ConversationOutbox(limits: limits, budget: budget)
        outboxes[threadId] = created
        return created
    }

    func remove(threadId: String) {
        outboxes.removeValue(forKey: threadId)?.removeAll()
    }

    func removeAll() {
        let existing = Array(outboxes.values)
        outboxes.removeAll()
        existing.forEach { $0.removeAll() }
    }
}
