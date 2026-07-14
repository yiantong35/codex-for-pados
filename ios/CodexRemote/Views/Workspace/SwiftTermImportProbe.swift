import SwiftTerm
import UIKit

/// 临时探针（Task 3 删除）：仅验证 SwiftTerm 依赖已成功接入、`TerminalView` 可被引用。
enum SwiftTermImportProbe {
    static func canReferenceTerminalView() -> Bool {
        // 引用类型即可触发链接；不实例化（避免需要 frame/delegate）。
        return TerminalView.self is AnyObject.Type
    }
}
