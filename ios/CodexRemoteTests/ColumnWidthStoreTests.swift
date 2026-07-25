import XCTest
import CoreGraphics
@testable import CodexRemote

@MainActor
final class ColumnWidthStoreTests: XCTestCase {
    private func makeStore() -> ColumnWidthStore {
        ColumnWidthStore(defaults: UserDefaults(suiteName: "cwtest.\(UUID().uuidString)")!)
    }

    func testNoRecordReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.widths(for: UUID()))
    }

    func testSaveThenReadRoundTrips() {
        let store = makeStore()
        let id = UUID()
        store.save(machineId: id, left: 260, right: 340)
        let w = store.widths(for: id)
        XCTAssertEqual(w?.left, 260)
        XCTAssertEqual(w?.right, 340)
    }

    func testSessionKeysAreIsolated() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.save(machineId: a, left: 260, right: 300)
        store.save(machineId: b, left: 400, right: 220)
        XCTAssertEqual(store.widths(for: a)?.left, 260)
        XCTAssertEqual(store.widths(for: a)?.right, 300)
        XCTAssertEqual(store.widths(for: b)?.left, 400)
        XCTAssertEqual(store.widths(for: b)?.right, 220)
    }

    func testPersistsAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: "cwtest.persist.\(UUID().uuidString)")!
        let id = UUID()
        ColumnWidthStore(defaults: defaults).save(machineId: id, left: 288, right: 333)
        let reopened = ColumnWidthStore(defaults: defaults)
        XCTAssertEqual(reopened.widths(for: id)?.left, 288)
        XCTAssertEqual(reopened.widths(for: id)?.right, 333)
    }

    func testResolveClampsStoredWidthAgainstNewTotal() {
        let store = makeStore()
        let id = UUID()
        store.save(machineId: id, left: 800, right: 800)
        let resolved = store.resolvedWidths(for: id, total: 1_000)
        let center = WorkspaceMetrics.centerColumnWidth(
            total: 1_000, left: resolved.left, right: resolved.right)
        XCTAssertGreaterThanOrEqual(center, WorkspaceMetrics.centerColumnMinWidth)
        XCTAssertLessThanOrEqual(resolved.left, WorkspaceMetrics.maxColumnWidth(total: 1_000))
        XCTAssertLessThanOrEqual(resolved.right, WorkspaceMetrics.maxColumnWidth(total: 1_000))
    }

    func testResolveReturnsDefaultsWhenNoRecord() {
        let store = makeStore()
        let resolved = store.resolvedWidths(for: UUID(), total: 1_200)
        XCTAssertEqual(resolved.left, WorkspaceMetrics.leftColumnDefaultWidth)
        XCTAssertEqual(resolved.right, WorkspaceMetrics.rightColumnDefaultWidth)
    }
}
