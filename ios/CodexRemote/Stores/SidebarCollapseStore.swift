import Foundation
import Observation

/// 项目分组折叠状态（按 project id 存一个折叠集合），内存 Set + UserDefaults 持久化。
/// 默认展开（不在集合中即展开）。
///
/// 必须是 `@Observable` class：DisclosureGroup 的 `isExpanded` 绑定 set 改的是这里的
/// `collapsedIDs`，只有可观察的内存状态变化才会触发 SwiftUI 重渲染。
/// （之前是 plain struct，setCollapsed 只写 UserDefaults 不触发渲染 → 点击文件夹无响应。）
@Observable
final class SidebarCollapseStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "sidebar.collapsedProjectIDs"

    private var collapsedIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.collapsedIDs = Set(defaults.stringArray(forKey: "sidebar.collapsedProjectIDs") ?? [])
    }

    func isCollapsed(_ id: String) -> Bool { collapsedIDs.contains(id) }

    func setCollapsed(_ id: String, _ collapsed: Bool) {
        if collapsed { collapsedIDs.insert(id) } else { collapsedIDs.remove(id) }
        defaults.set(Array(collapsedIDs), forKey: key)
    }
}
