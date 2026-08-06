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
