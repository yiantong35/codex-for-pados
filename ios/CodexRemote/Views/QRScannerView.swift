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

    final class PreviewView: UIView {
        var onScan: ((String) -> Void)?
        private var didScan = false
        private lazy var captureWorker = QRScannerCaptureWorker { @MainActor [weak self] value in
            guard let self, !didScan else { return }
            didScan = true
            onScan?(value)
        }

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        enum CameraAction: Equatable { case start, stop, noop }

        /// 纯对齐决策（可单测）：目标态 vs 实际运行态 → 该做的动作。
        /// 纯函数无状态依赖，标 nonisolated 便于非主 actor 的单测直接调用。
        nonisolated static func reconcile(desired: Bool, isRunning: Bool) -> CameraAction {
            switch (desired, isRunning) {
            case (true, false):  return .start
            case (false, true):  return .stop
            default:             return .noop
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            captureWorker.attach(to: previewLayer)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            captureWorker.attach(to: previewLayer)
        }

        func start() {
            captureWorker.start()
        }

        func stop() {
            // Always enqueue stop so it is ordered after an earlier start request.
            captureWorker.stop()
        }
    }
}

/// Owns all blocking AVCaptureSession work on one serial queue. It is deliberately separate from
/// PreviewView so no UIView/MainActor state is ever captured by the capture queue.
private final class QRScannerCaptureWorker: NSObject, AVCaptureMetadataOutputObjectsDelegate,
                                            @unchecked Sendable {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.codexremote.qr.capture")
    private let onScan: @MainActor @Sendable (String) -> Void
    private var desiredRunning = false
    private var inputConfigured = false
    private var didScan = false

    init(onScan: @escaping @MainActor @Sendable (String) -> Void) {
        self.onScan = onScan
    }

    @MainActor
    func attach(to previewLayer: AVCaptureVideoPreviewLayer) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start() {
        captureQueue.async { self.setDesired(true) }
    }

    func stop() {
        captureQueue.async { self.setDesired(false) }
    }

    private func setDesired(_ running: Bool) {
        desiredRunning = running
        switch QRScannerView.PreviewView.reconcile(desired: desiredRunning,
                                                   isRunning: session.isRunning) {
        case .start:
            configureInputsIfNeeded()
            guard !session.inputs.isEmpty else { return }
            session.startRunning()
        case .stop:
            session.stopRunning()
        case .noop:
            break
        }
    }

    private func configureInputsIfNeeded() {
        guard !inputConfigured else { return }
        inputConfigured = true
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: captureQueue)
        output.metadataObjectTypes = [.qr]
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard !didScan,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        didScan = true
        Task { @MainActor [onScan] in onScan(value) }
        setDesired(false)
    }
}
