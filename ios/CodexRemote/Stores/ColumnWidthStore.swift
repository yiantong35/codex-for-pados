import Foundation
import CoreGraphics
import Observation

/// 列宽 session 级持久化层（custom-resizable-columns，D7）。
/// key = `colWidth.<machineUUID>`，存该机的 (left, right)。override-first 范式
/// （对齐 ShortcutStore / SidebarCollapseStore）：无记录返回 nil，由调用方回落默认宽。
/// 不同机器 tab 各记各的列宽，切 tab 读回、冷启动 / 进程回收从 UserDefaults 恢复。
@Observable
@MainActor
final class ColumnWidthStore {
    struct Widths: Codable, Equatable {
        var left: CGFloat
        var right: CGFloat
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let keyPrefix = "colWidth."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ id: UUID) -> String { Self.keyPrefix + id.uuidString }

    func widths(for id: UUID) -> Widths? {
        guard let data = defaults.data(forKey: key(id)),
              let w = try? JSONDecoder().decode(Widths.self, from: data) else { return nil }
        return w
    }

    func save(machineId id: UUID, left: CGFloat, right: CGFloat) {
        let w = Widths(left: left, right: right)
        guard let data = try? JSONEncoder().encode(w) else { return }
        defaults.set(data, forKey: key(id))
    }

    /// Resolve persisted user preferences independently of the current window width. The layout
    /// derives effective render widths for each container size without overwriting these values.
    func preferredWidths(for id: UUID?) -> Widths {
        guard let id, let stored = widths(for: id) else {
            return Widths(left: WorkspaceMetrics.leftColumnDefaultWidth,
                          right: WorkspaceMetrics.rightColumnDefaultWidth)
        }
        return Widths(
            left: WorkspaceMetrics.clamp(
                stored.left,
                min: WorkspaceMetrics.leftColumnMinWidth,
                max: WorkspaceMetrics.rightPanelMaxWidth),
            right: WorkspaceMetrics.clamp(
                stored.right,
                min: WorkspaceMetrics.rightColumnMinWidth,
                max: WorkspaceMetrics.rightPanelMaxWidth))
    }
}
