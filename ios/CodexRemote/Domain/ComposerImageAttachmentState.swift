import Foundation
import Observation
import SwiftUI
import PhotosUI

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
    private(set) var isLoading = false
    private(set) var loadFailed = false

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
        isLoading = true
        loadFailed = false
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
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    func clear() {
        invalidateTask()
        dataURL = nil
        error = nil
        isLoading = false
        loadFailed = false
    }

    func restore(dataURL: String?) {
        invalidateTask()
        self.dataURL = dataURL
        error = nil
        isLoading = false
        loadFailed = false
    }

#if DEBUG
    var hasActiveTaskForTesting: Bool { task != nil }
#endif

    private func apply(_ result: ImageEncodeResult, token resultToken: UUID) {
        guard token == resultToken else { return }
        task = nil
        isLoading = false
        switch result {
        case .ok(let url, _):
            dataURL = url
            error = nil
            loadFailed = false
        case .tooLarge(let bytes, let limit):
            dataURL = nil
            error = ComposerImageAttachmentError(bytes: bytes, limit: limit)
            loadFailed = false
        case .cancelled:
            loadFailed = true
        }
    }

    private func invalidateTask() {
        token = nil
        task?.cancel()
        task = nil
    }
}

/// A composer draft belongs to one thread. Session owns the surrounding store, so the
/// same thread id on two machines cannot share text, attachments, or model overrides.
@Observable
@MainActor
final class ComposerDraft {
    var text = ""
    var photoItem: PhotosPickerItem?
    let imageAttachment: ComposerImageAttachmentState
    var selection = ModelSelection()

    init(imageAttachment: ComposerImageAttachmentState = ComposerImageAttachmentState()) {
        self.imageAttachment = imageAttachment
    }

    func clearInput() {
        text = ""
        photoItem = nil
        imageAttachment.clear()
    }

    func restore(_ message: PendingConversationMessage) {
        text = message.input.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.joined()
        let imageURL = message.input.compactMap { input -> String? in
            if case .image(let url, _) = input { return url }
            return nil
        }.first
        photoItem = nil
        imageAttachment.restore(dataURL: imageURL)
        selection.modelOverride = message.model
        selection.effortOverride = message.effort
    }
}

@Observable
@MainActor
final class ComposerDraftStore {
    @ObservationIgnored private var drafts: [String: ComposerDraft] = [:]

    func draft(for threadId: String) -> ComposerDraft {
        if let existing = drafts[threadId] { return existing }
        let draft = ComposerDraft()
        drafts[threadId] = draft
        return draft
    }

    func removeDraft(for threadId: String) {
        drafts.removeValue(forKey: threadId)?.clearInput()
    }

    func removeAll() {
        let existing = Array(drafts.values)
        drafts.removeAll()
        existing.forEach { $0.clearInput() }
    }

#if DEBUG
    var draftCountForTesting: Int { drafts.count }
#endif
}
