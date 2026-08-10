import Foundation
import Observation

struct PendingConversationMessage {
    let input: [UserInput]
    let model: String?
    let effort: ReasoningEffort?
    let clientId: String

    var localId: String { "local-\(clientId)" }
}

/// Thread-scoped outbound state. Session owners retain this object across view and RPC rebuilds.
@Observable
@MainActor
final class ConversationOutbox {
    private(set) var entries: [PendingConversationMessage] = []
    private var sendingClientId: String?
    private var rpcIdentity: ObjectIdentifier?

    var queuedEntries: [PendingConversationMessage] {
        entries.filter { $0.clientId != sendingClientId }
    }

    func attach(to rpc: JSONRPCClient) {
        let identity = ObjectIdentifier(rpc)
        if let rpcIdentity, rpcIdentity != identity {
            sendingClientId = nil
        }
        rpcIdentity = identity
    }

    func enqueue(input: [UserInput], model: String?, effort: ReasoningEffort?) -> PendingConversationMessage {
        let entry = PendingConversationMessage(
            input: input,
            model: model,
            effort: effort,
            clientId: UUID().uuidString
        )
        entries.append(entry)
        return entry
    }

    func beginSending() -> PendingConversationMessage? {
        guard sendingClientId == nil, let entry = entries.first else { return nil }
        sendingClientId = entry.clientId
        return entry
    }

    func acknowledge(clientId: String) {
        entries.removeAll { $0.clientId == clientId }
    }

    func acknowledgeSending() {
        guard let sendingClientId else { return }
        acknowledge(clientId: sendingClientId)
        self.sendingClientId = nil
    }

    func failSending(clientId: String) {
        if sendingClientId == clientId { sendingClientId = nil }
    }

    func reconcileAuthoritativeState() {
        sendingClientId = nil
    }
}

@Observable
@MainActor
final class ConversationOutboxRegistry {
    private var outboxes: [String: ConversationOutbox] = [:]

    func outbox(for threadId: String) -> ConversationOutbox {
        if let existing = outboxes[threadId] { return existing }
        let created = ConversationOutbox()
        outboxes[threadId] = created
        return created
    }

    func remove(threadId: String) {
        outboxes.removeValue(forKey: threadId)
    }
}
