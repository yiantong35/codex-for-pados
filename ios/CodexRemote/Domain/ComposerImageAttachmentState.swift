import Foundation
import Observation

struct ComposerImageAttachmentError: Equatable {
    let bytes: Int
    let limit: Int
}

@Observable
@MainActor
final class ComposerImageAttachmentState {
    typealias Encoder = @Sendable (Data) async -> ImageEncodeResult

    private(set) var dataURL: String?
    private(set) var error: ComposerImageAttachmentError?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private let encode: Encoder

    init(encode: @escaping Encoder = { await ImageEncoder.encodeForSend($0) }) {
        self.encode = encode
    }

    func load(_ loadData: @escaping @MainActor () async throws -> Data) {
        invalidateTask()
        dataURL = nil
        error = nil
        let nextToken = UUID()
        token = nextToken

        task = Task { [weak self] in
            do {
                let data = try await loadData()
                guard !Task.isCancelled, let self else { return }
                let result = await self.encode(data)
                guard !Task.isCancelled else { return }
                self.apply(result, token: nextToken)
            } catch is CancellationError {
                // A replacement, removal, send, or disappearance intentionally cancelled loading.
            } catch {
                guard let self, self.token == nextToken else { return }
                self.task = nil
            }
        }
    }

    func clear() {
        invalidateTask()
        dataURL = nil
        error = nil
    }

#if DEBUG
    var hasActiveTaskForTesting: Bool { task != nil }
#endif

    private func apply(_ result: ImageEncodeResult, token resultToken: UUID) {
        guard token == resultToken else { return }
        task = nil
        switch result {
        case .ok(let url, _):
            dataURL = url
            error = nil
        case .tooLarge(let bytes, let limit):
            dataURL = nil
            error = ComposerImageAttachmentError(bytes: bytes, limit: limit)
        case .cancelled:
            break
        }
    }

    private func invalidateTask() {
        token = nil
        task?.cancel()
        task = nil
    }
}
