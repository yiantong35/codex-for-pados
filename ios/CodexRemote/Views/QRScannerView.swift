import SwiftUI
import AVFoundation

/// 相机扫码视图：AVCaptureMetadataOutput 识别 `.qr`，扫到即回调字符串。
///
/// 仅负责「扫到一个字符串」，后续解析/配对复用 RelayPairingImportViewModel 走既有路径。
/// 相机不可用（如模拟器 `AVCaptureDevice.default(for:.video) == nil`）时 `start()` 直接返回，
/// 预览层保持黑屏但不崩溃；上层已在 present 前处理权限/可用性回退，此处再兜一层。
struct QRScannerView: UIViewRepresentable {
    /// 扫到二维码字符串的回调（主线程）。首次命中后会话即停止，避免重复回调。
    var onScan: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.onScan = onScan
        v.start()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// 视图销毁时停止会话，释放相机。
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.stop()
    }

    /// 把非 Sendable 的 AVCaptureSession 安全带过并发边界（仅在专用队列 start/stop，无并发写）。
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
    }

    final class PreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        // session 由 AVFoundation 内部线程与主线程共同触碰；标 nonisolated(unsafe) 以在
        // detached 任务中安全 start/stop（回调统一走 .main 队列，实际无并发写）。
        private nonisolated(unsafe) let session = AVCaptureSession()
        private var didScan = false

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func start() {
            // 相机不可用（模拟器/无权限）→ 静默返回，不崩溃；上层负责提示与回退。
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill

            // startRunning 是阻塞调用，放后台队列避免卡主线程；用 @unchecked Sendable 盒穿越并发边界。
            let box = SessionBox(session: session)
            DispatchQueue.global(qos: .userInitiated).async { box.session.startRunning() }
        }

        func stop() {
            guard session.isRunning else { return }
            let box = SessionBox(session: session)
            DispatchQueue.global(qos: .userInitiated).async { box.session.stopRunning() }
        }

        // 回调队列设为 .main（见 start()），故此 nonisolated 要求可安全断言在主 actor 执行。
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            // 先在 nonisolated 上下文取出 Sendable 的 String，再进主 actor，避免发送非 Sendable 对象。
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let s = obj.stringValue else { return }
            MainActor.assumeIsolated {
                guard !didScan else { return }
                didScan = true
                session.stopRunning()
                onScan?(s)
            }
        }
    }
}
