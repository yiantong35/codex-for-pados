import Foundation
import Observation

@Observable
@MainActor
final class McpElicitationStore {
    typealias Resolver = @MainActor (RequestId, McpServerElicitationRequestResponse) async -> Bool

    private(set) var cards: [McpElicitationCard] = []
    private(set) var submissionStates: [RequestId: DecisionSubmissionState] = [:]
    private(set) var expiredRecoveryIds: Set<RequestId> = []
    var resolver: Resolver?

    func handle(request: JSONRPCRequest) throws {
        let card = try McpElicitationCard(request: request)
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
        submissionStates[card.id] = .idle
        expiredRecoveryIds.remove(card.id)
    }

    @discardableResult
    func accept(card: McpElicitationCard, drafts: [String: McpFormDraft]) async -> Bool {
        guard let current = cards.first(where: { $0.id == card.id }), !current.awaitingRecovery,
              let response = try? current.accept(drafts: drafts)
        else { return false }
        return await deliver(card: current, response: response)
    }

    @discardableResult
    func resolve(card: McpElicitationCard, action: McpServerElicitationAction) async -> Bool {
        guard let current = cards.first(where: { $0.id == card.id }), !current.awaitingRecovery else { return false }
        return await deliver(card: current, response: current.response(action: action))
    }

    func handleServerRequestResolved(_ id: RequestId) {
        cards.removeAll { $0.id == id }
        submissionStates[id] = nil
    }

    func handleConnectionLost() {
        for index in cards.indices { cards[index].awaitingRecovery = true }
        for id in submissionStates.keys { submissionStates[id] = .idle }
    }

    var hasAwaitingRecovery: Bool { cards.contains { $0.awaitingRecovery } }
    func expireAwaitingRecovery() {
        for index in cards.indices where cards[index].awaitingRecovery {
            cards[index].awaitingRecovery = false
            expiredRecoveryIds.insert(cards[index].id)
        }
    }
    func discardExpired(_ id: RequestId) {
        cards.removeAll { $0.id == id }
        submissionStates[id] = nil
        expiredRecoveryIds.remove(id)
    }

    func removeAll(threadId: String) {
        let ids = cards.filter { $0.threadId == threadId }.map(\.id)
        cards.removeAll { $0.threadId == threadId }
        for id in ids { submissionStates[id] = nil }
    }

    func submissionState(for id: RequestId) -> DecisionSubmissionState {
        submissionStates[id] ?? .idle
    }

    private func deliver(card: McpElicitationCard, response: McpServerElicitationRequestResponse) async -> Bool {
        guard submissionState(for: card.id) != .submitting else { return false }
        submissionStates[card.id] = .submitting
        guard let resolver, await resolver(card.id, response) else {
            submissionStates[card.id] = .failed
            return false
        }
        cards.removeAll { $0.id == card.id }
        submissionStates[card.id] = nil
        return true
    }
}
