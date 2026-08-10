import XCTest
@testable import CodexRemote

@MainActor
final class ComposerImageAttachmentTests: XCTestCase {
    func test_slow_old_selection_cannot_overwrite_new_selection() async throws {
        let encoder = DeferredAttachmentEncoder()
        let state = ComposerImageAttachmentState(encode: { await encoder.encode($0) })

        state.load { Data([1]) }
        try await waitUntil { await encoder.hasStarted(1) }
        state.load { Data([2]) }
        try await waitUntil { await encoder.hasStarted(2) }

        await encoder.resolve(2, with: .ok(dataURL: "new", bytes: 3))
        try await waitUntil { state.dataURL == "new" }
        await encoder.resolve(1, with: .ok(dataURL: "old", bytes: 3))
        await Task.yield()

        XCTAssertEqual(state.dataURL, "new")
        XCTAssertNil(state.error)
    }

    func test_clear_rejects_late_result_and_cancels_active_task() async throws {
        let encoder = DeferredAttachmentEncoder()
        let state = ComposerImageAttachmentState(encode: { await encoder.encode($0) })

        state.load { Data([3]) }
        try await waitUntil { await encoder.hasStarted(3) }
        XCTAssertTrue(state.hasActiveTaskForTesting)

        state.clear()
        XCTAssertFalse(state.hasActiveTaskForTesting)
        await encoder.resolve(3, with: .ok(dataURL: "stale", bytes: 5))
        await Task.yield()

        XCTAssertNil(state.dataURL)
        XCTAssertNil(state.error)
    }

    func test_load_failure_is_visible_and_retryable() async throws {
        let state = ComposerImageAttachmentState()

        state.load { throw ComposerImageAttachmentTestError.timeout }
        try await waitUntil { state.loadFailed }

        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.dataURL)

        state.load { Data([1]) }
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.loadFailed)
    }

    func test_text_cannot_send_while_image_is_loading() {
        XCTAssertFalse(ComposerView.canSend(text: "hello", imageDataURL: nil, isImageLoading: true))
        XCTAssertTrue(ComposerView.canSend(text: "hello", imageDataURL: nil, isImageLoading: false))
        XCTAssertTrue(ComposerView.canSend(text: "", imageDataURL: "data:image/jpeg;base64,x", isImageLoading: false))
    }

    func test_drafts_are_stable_per_thread_and_isolated_between_threads() {
        let store = ComposerDraftStore()
        let first = store.draft(for: "thread-a")
        first.text = "unfinished"
        first.selection.effortOverride = .high

        XCTAssertTrue(first === store.draft(for: "thread-a"))
        XCTAssertEqual(store.draft(for: "thread-a").text, "unfinished")
        XCTAssertEqual(store.draft(for: "thread-a").selection.effortOverride, .high)
        XCTAssertFalse(first === store.draft(for: "thread-b"))
        XCTAssertEqual(store.draft(for: "thread-b").text, "")
    }

    func test_clear_input_keeps_model_selection() {
        let draft = ComposerDraft()
        draft.text = "sent"
        draft.selection.modelOverride = "test-model"
        draft.selection.effortOverride = .xhigh

        draft.clearInput()

        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.selection.modelOverride, "test-model")
        XCTAssertEqual(draft.selection.effortOverride, .xhigh)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out")
        throw ComposerImageAttachmentTestError.timeout
    }
}

private actor DeferredAttachmentEncoder {
    private var started: Set<UInt8> = []
    private var continuations: [UInt8: CheckedContinuation<ImageEncodeResult, Never>] = [:]
    private var earlyResults: [UInt8: ImageEncodeResult] = [:]

    func encode(_ data: Data) async -> ImageEncodeResult {
        let key = data.first ?? 0
        started.insert(key)
        if let result = earlyResults.removeValue(forKey: key) { return result }
        return await withCheckedContinuation { continuations[key] = $0 }
    }

    func hasStarted(_ key: UInt8) -> Bool { started.contains(key) }

    func resolve(_ key: UInt8, with result: ImageEncodeResult) {
        if let continuation = continuations.removeValue(forKey: key) {
            continuation.resume(returning: result)
        } else {
            earlyResults[key] = result
        }
    }
}

private enum ComposerImageAttachmentTestError: Error { case timeout }
