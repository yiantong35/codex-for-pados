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

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // 订阅输出字节：在主线程 feed 给 SwiftTerm（onBytes 已在 @MainActor 上触发）。
        session.onBytes = { [weak view] bytes in
            view?.feed(byteArray: ArraySlice(bytes))
        }
        context.coordinator.terminalView = view
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // 尺寸/布局由父容器 frame 驱动；SwiftTerm 自身在 layoutSubviews 里重算 cols/rows
        // 并回调 sizeChanged → resize。此处无需额外同步。
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
