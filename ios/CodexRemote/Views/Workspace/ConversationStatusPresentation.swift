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

    /// loadState=nil（无会话选中）→ nil：胶囊+刷新按钮整块隐藏（spec：无会话选中时隐藏）。
    static func descriptor(loadState: ConversationLoadState?, isTurnRunning: Bool) -> Descriptor? {
        guard let loadState else { return nil }
        switch loadState {
        case .loading:
            return Descriptor(key: "conv.loading", symbol: "arrow.clockwise", tint: .secondary)
        case .failed:
            return Descriptor(key: "conv.loadFailed", symbol: "exclamationmark.triangle.fill", tint: .red)
        case .idle, .loaded:
            return isTurnRunning
                ? Descriptor(key: "conv.running", symbol: "circle.fill", tint: .orange)
                : Descriptor(key: "conv.idle", symbol: "checkmark.circle", tint: .secondary)
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
