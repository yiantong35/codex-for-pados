import Foundation
import Observation

@Observable
@MainActor
final class McpElicitationStore {
    typealias Resolver = @MainActor (RequestId, McpServerElicitationRequestResponse) async -> Bool

    private(set) var cards: [McpElicitationCard] = []
    var resolver: Resolver?

    func handle(request: JSONRPCRequest) throws {
        let card = try McpElicitationCard(request: request)
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
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
    }

    func handleConnectionLost() {
        for index in cards.indices { cards[index].awaitingRecovery = true }
    }

    private func deliver(card: McpElicitationCard, response: McpServerElicitationRequestResponse) async -> Bool {
        guard let resolver, await resolver(card.id, response) else { return false }
        cards.removeAll { $0.id == card.id }
        return true
    }
}
