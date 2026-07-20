import SwiftUI

/// 已知 iPadOS 系统保留键黑名单（设计 D3）。硬阻改键命中项。
/// 非目标：不保证穷举全部系统保留键——只尽力拦已知项，文案用「系统保留键」而非「保证可用」。
enum SystemReservedShortcuts {
    static let all: Set<KeyCombo> = [
        KeyCombo(key: " ", modifiers: .command),            // ⌘Space（聚焦/输入法）
        KeyCombo(key: "\t", modifiers: .command),           // ⌘Tab（app 切换）
        KeyCombo(key: "h", modifiers: .command),            // ⌘H（回主屏）
        KeyCombo(key: "`", modifiers: .command),            // ⌘`（窗口循环）
        KeyCombo(key: "3", modifiers: [.command, .shift]),  // ⌘⇧3（截屏）
        KeyCombo(key: "4", modifiers: [.command, .shift]),  // ⌘⇧4（区域截屏）
    ]
}
