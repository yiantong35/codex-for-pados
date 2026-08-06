import Foundation
import Observation

@Observable
@MainActor
final class UserInputStore {
    typealias Resolver = @MainActor (RequestId, ToolRequestUserInputResponse) async -> Bool
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private(set) var cards: [UserInputCard] = []
    var resolver: Resolver?

    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private var timers: [RequestId: Task<Void, Never>] = [:]

    init(sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
    }

    func handle(request: JSONRPCRequest) throws {
        let card = try UserInputCard(request: request)
        timers[card.id]?.cancel()
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
        scheduleAutoResolution(for: card)
    }

    @discardableResult
    func submit(card: UserInputCard, drafts: [String: UserInputDraft]) async -> Bool {
        guard let current = cards.first(where: { $0.id == card.id }), !current.awaitingRecovery,
              let response = try? current.response(drafts: drafts)
        else { return false }
        return await resolve(card: current, response: response)
    }

    @discardableResult
    func cancel(card: UserInputCard) async -> Bool {
        guard let current = cards.first(where: { $0.id == card.id }), !current.awaitingRecovery else {
            return false
        }
        return await resolve(card: current, response: .init(answers: [:]))
    }

    func userInteracted(with id: RequestId) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    func handleServerRequestResolved(_ id: RequestId) {
        remove(id)
    }

    func handleConnectionLost() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for index in cards.indices { cards[index].awaitingRecovery = true }
    }

    private func scheduleAutoResolution(for card: UserInputCard) {
        guard let milliseconds = card.autoResolutionMs else { return }
        let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let delay = nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
        timers[card.id] = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  let current = self.cards.first(where: { $0.id == card.id }),
                  !current.awaitingRecovery
            else { return }
            _ = await self.resolve(card: current, response: .init(answers: [:]))
        }
    }

    private func resolve(card: UserInputCard, response: ToolRequestUserInputResponse) async -> Bool {
        timers[card.id]?.cancel()
        timers[card.id] = nil
        guard let resolver, await resolver(card.id, response) else { return false }
        remove(card.id)
        return true
    }

    private func remove(_ id: RequestId) {
        timers[id]?.cancel()
        timers[id] = nil
        cards.removeAll { $0.id == id }
    }
}
