import Foundation
import Observation

enum FullDiffLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

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
    private(set) var loadState: FullDiffLoadState = .idle
    var isLoading: Bool { loadState == .loading }
    var hasError: Bool { loadState == .failed }
    private var generation: UInt64 = 0

    func invalidate(for newContext: FullDiffContextKey?) {
        guard context != newContext else { return }
        generation &+= 1
        context = newContext
        diff = nil
        loadState = .idle
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
        loadState = .loading
        let value = await fetch(context.cwd)
        guard owner == generation, self.context == context else { return false }
        if let value {
            diff = value
            loadState = .loaded
            return true
        }
        diff = nil
        loadState = .failed
        return false
    }
}
