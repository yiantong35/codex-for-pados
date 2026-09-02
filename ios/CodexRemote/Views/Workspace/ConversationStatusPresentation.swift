import SwiftUI

/// 状态胶囊四态映射（toolbar-status-and-jump-to-latest design §2a）：纯函数无 UI 依赖可单测，
/// WorkspaceToolbar 读取渲染。四态语义/配色/优先级沿用原 ConversationView 自挂 ToolbarItem
/// （loading > failed > running > idle）。
enum ConversationStatusPresentation {
    struct Descriptor: Equatable {
        let key: String       // Localizable.xcstrings key（四态 key 均已存在）
        let symbol: String    // SF Symbol
        let tint: Tint
    }
    /// 语义色（Color 映射放视图层扩展，保持本类型可在无 SwiftUI 语境断言）。
    enum Tint { case secondary, red, orange }

    /// 只在「加载中/加载失败」两态显示胶囊（用户 2026-09-02 定案：运行/空闲不显示——
    /// 侧栏 session 徽标已覆盖运行状态）；nil/正常态 → nil 隐藏胶囊（刷新按钮独立常驻）。
    static func descriptor(loadState: ConversationLoadState?) -> Descriptor? {
        switch loadState {
        case .loading:
            return Descriptor(key: "conv.loading", symbol: "arrow.clockwise", tint: .secondary)
        case .failed:
            return Descriptor(key: "conv.loadFailed", symbol: "exclamationmark.triangle.fill", tint: .red)
        case .idle, .loaded, nil:
            return nil
        }
    }

    /// 加载进行中禁用刷新（防抖，spec：加载进行中 SHALL 禁用）；nil 时整块隐藏，取值不影响。
    static func shouldDisableRefresh(loadState: ConversationLoadState?) -> Bool {
        loadState == .loading
    }
}

extension ConversationStatusPresentation.Tint {
    var color: Color {
        switch self {
        case .secondary: return .secondary
        case .red: return .red
        case .orange: return .orange
        }
    }
}
