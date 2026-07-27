import SwiftUI
import SwiftTerm

/// 桥接纯逻辑（可单测，不依赖 UIKit TerminalView）：把 SwiftTerm 事件映射到 TerminalSession。
/// SwiftTermView.Coordinator 持有一个实例并在 delegate 回调中转发。
@MainActor
final class TerminalBridge {
    private let session: TerminalSession
    init(session: TerminalSession) { self.session = session }

    /// delegate.send(data) → PTY stdin。字节转 UTF-8 字符串（sendInput 内部再 base64）。
    func handleSend(bytes: ArraySlice<UInt8>) {
        session.sendInput(String(decoding: bytes, as: UTF8.self))
    }

    /// delegate.sizeChanged → command/exec/resize（注意 rows/cols 顺序）。
    func handleSizeChanged(newCols: Int, newRows: Int) {
        session.resize(CommandExecTerminalSize(rows: newRows, cols: newCols))
    }
}

/// SwiftUI 包装 SwiftTerm.TerminalView：makeUIView 建视图+设 delegate；
/// Coordinator 实现 TerminalViewDelegate 桥接 TerminalSession，并订阅 session.onBytes feed 输出。
struct SwiftTermView: UIViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// 按当前深浅色给 TerminalView 设高对比配色。
    /// 深色：亮前景 + 暗背景；浅色：暗前景 + 亮背景。
    /// nativeBackgroundColor 在库内会被复位为 clear（layer.backgroundColor 承载），
    /// 故同时设视图 backgroundColor 保证背景实际生效（设计文档 A）。
    private func applyColors(to view: TerminalView, scheme: ColorScheme) {
        let foreground: UIColor
        if scheme == .dark {
            foreground = UIColor(white: 0.92, alpha: 1.0)   // 近白，暗背景高对比
        } else {
            foreground = UIColor(white: 0.12, alpha: 1.0)   // 近黑，亮背景高对比
        }
        // 背景与各列统一：解析 systemBackground 到当前深浅（深色=纯黑 / 浅色=纯白），
        // 不再用独立灰底（原 0.11/0.98 会显得与相邻列不一致）。
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let background = UIColor.systemBackground.resolvedColor(with: traits)
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
        view.backgroundColor = background
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        applyColors(to: view, scheme: colorScheme)
        // 订阅输出字节：在主线程 feed 给 SwiftTerm（onBytes 已在 @MainActor 上触发）。
        session.onBytes = { [weak view] bytes in
            view?.feed(byteArray: ArraySlice(bytes))
        }
        context.coordinator.terminalView = view
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // 尺寸/布局由父容器 frame 驱动；SwiftTerm 自身在 layoutSubviews 里重算 cols/rows。
        // colorScheme 变化时（深浅切换）同步终端配色（设计文档 A）。
        applyColors(to: uiView, scheme: context.environment.colorScheme)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        // 视图销毁：断开 onBytes 引用，避免 feed 到已释放视图。
        coordinator.session.onBytes = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        let bridge: TerminalBridge
        weak var terminalView: TerminalView?

        init(session: TerminalSession) {
            self.session = session
            self.bridge = TerminalBridge(session: session)
        }

        // TerminalViewDelegate 非 @MainActor；SwiftTerm 在主线程回调，故用 assumeIsolated 桥回主 actor。

        // 用户输入字节 → PTY stdin
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { bridge.handleSend(bytes: data) }
        }

        // 终端几何变化 → resize
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { bridge.handleSizeChanged(newCols: newCols, newRows: newRows) }
        }

        // 以下 delegate 方法当前无需处理，空实现（编译若要求更多方法，按报错补齐）。
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
            }
        }
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            MainActor.assumeIsolated {
                if let url = URL(string: link) { UIApplication.shared.open(url) }
            }
        }
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
