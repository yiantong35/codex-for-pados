import Foundation
import Observation

struct FullDiffContextKey: Equatable, Sendable {
    let cwd: String
    let conversationIdentity: String
    let fetchGeneration: Int

    init(cwd: String, conversationIdentity: String, fetchGeneration: Int = 0) {
        self.cwd = cwd
        self.conversationIdentity = conversationIdentity
        self.fetchGeneration = fetchGeneration
    }
}

@Observable
@MainActor
final class FullDiffSnapshotModel {
    private(set) var diff: String?
    private(set) var context: FullDiffContextKey?
    private(set) var isLoading = false
    private var generation: UInt64 = 0

    func invalidate(for newContext: FullDiffContextKey?) {
        guard context != newContext else { return }
        generation &+= 1
        context = newContext
        diff = nil
        isLoading = false
    }

    @discardableResult
    func ensureLoaded(context: FullDiffContextKey,
                      fetch: @escaping (String) async -> String?) async -> Bool {
        invalidate(for: context)
        guard diff == nil else { return true }
        return await refresh(context: context, fetch: fetch)
    }

    @discardableResult
    func refresh(context: FullDiffContextKey,
                 fetch: @escaping (String) async -> String?) async -> Bool {
        invalidate(for: context)
        generation &+= 1
        let owner = generation
        isLoading = true
        let value = await fetch(context.cwd)
        guard owner == generation, self.context == context else { return false }
        if let value { diff = value }
        isLoading = false
        return value != nil
    }
}
