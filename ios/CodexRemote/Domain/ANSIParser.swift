import SwiftUI

/// 基础 ANSI SGR 解析状态机（MVP，下边栏终端）：解析 \x1b[...m 颜色/加粗，
/// 光标定位等非 SGR 序列丢弃。保留跨 feed 未完成序列状态（outputDelta 分片可能切断序列）。
struct ANSIParser {
    struct Run: Equatable { var text: String; var color: Color?; var bold: Bool }

    private enum State { case text, esc, csi }   // csi: 收集 \x1b[ 后参数直到字母
    private var state: State = .text
    private var csiBuffer = ""            // CSI 参数累积（跨 feed 保留）
    private var currentColor: Color?
    private var currentBold = false

    mutating func feed(_ chunk: String) -> [Run] {
        var runs: [Run] = []
        var text = ""
        func flush() {
            if !text.isEmpty { runs.append(Run(text: text, color: currentColor, bold: currentBold)); text = "" }
        }
        for ch in chunk {
            switch state {
            case .text:
                if ch == "\u{1b}" { flush(); state = .esc }
                else { text.append(ch) }
            case .esc:
                if ch == "[" { state = .csi; csiBuffer = "" } else { state = .text }  // 非 CSI 忽略
            case .csi:
                if ch.isLetter {
                    if ch == "m" { flush(); applySGR(csiBuffer) }   // 仅处理 SGR(m)，其余(H/J/K…)丢弃
                    csiBuffer = ""; state = .text
                } else {
                    csiBuffer.append(ch)   // 参数/中间字节，跨 feed 累积
                }
            }
        }
        flush()
        return runs
    }

    private mutating func applySGR(_ params: String) {
        let codes = params.split(separator: ";").map { Int($0) ?? 0 }
        for c in (codes.isEmpty ? [0] : codes) {
            switch c {
            case 0: currentColor = nil; currentBold = false
            case 1: currentBold = true
            case 22: currentBold = false
            case 30...37: currentColor = Self.ansiColor(c - 30)
            case 39: currentColor = nil
            case 90...97: currentColor = Self.ansiColor(c - 90)
            default: break
            }
        }
    }
    private static func ansiColor(_ i: Int) -> Color? {
        let table: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .gray]
        return table.indices.contains(i) ? table[i] : nil
    }
}
