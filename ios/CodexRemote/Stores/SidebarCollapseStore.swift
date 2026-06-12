import Foundation

/// 项目分组折叠状态的本地持久化（按 project id 存一个折叠集合）。
/// 默认展开（不在集合中即展开）。
struct SidebarCollapseStore {
    private let defaults: UserDefaults
    private let key = "sidebar.collapsedProjectIDs"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var collapsedIDs: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    func isCollapsed(_ id: String) -> Bool { collapsedIDs.contains(id) }
    func setCollapsed(_ id: String, _ collapsed: Bool) {
        var ids = collapsedIDs
        if collapsed { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: key)
    }
}
