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

    final class PreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        // session 由 AVFoundation 内部线程与主线程共同触碰；标 nonisolated(unsafe)：写入已统一
        // 串行化到 captureQueue，主队列的 delegate 只读 + 调度，故实际无并发写。
        private nonisolated(unsafe) let session = AVCaptureSession()
        private var didScan = false

        // #4：单一私有串行队列 + 目标运行态，保证 start/stop 顺序对齐、最终态收敛。
        private let captureQueue = DispatchQueue(label: "com.codexremote.qr.capture")
        private var desiredRunning = false          // 仅在 captureQueue 上读写
        private var inputConfigured = false         // 首次对齐时懒配置 input/output

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

        func start() {
            captureQueue.async { [weak self] in self?.setDesired(true) }
        }

        func stop() {
            // 无条件排队（删掉 isRunning 早退）：保证 dismantle 的 stop 一定排在先前 start 之后。
            captureQueue.async { [weak self] in self?.setDesired(false) }
        }

        /// 仅在 captureQueue 上执行：更新目标态并把实际态对齐过去。
        private func setDesired(_ running: Bool) {
            desiredRunning = running
            switch Self.reconcile(desired: desiredRunning, isRunning: session.isRunning) {
            case .start:
                configureInputsIfNeeded()
                guard session.inputs.isEmpty == false else { return }   // 相机不可用（模拟器）→ 不启
                session.startRunning()
            case .stop:
                session.stopRunning()
            case .noop:
                break
            }
        }

        /// 懒配置 input/output（仅一次）。相机不可用时静默返回，session.inputs 保持空。
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
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.previewLayer.session = self.session
                self.previewLayer.videoGravity = .resizeAspectFill
            }
        }

        // 回调队列设为 .main（见 configureInputsIfNeeded()），故此 nonisolated 要求可安全断言在主 actor 执行。
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            // 先在 nonisolated 上下文取出 Sendable 的 String，再进主 actor，避免发送非 Sendable 对象。
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let s = obj.stringValue else { return }
            MainActor.assumeIsolated {
                guard !didScan else { return }
                didScan = true
                onScan?(s)
            }
            // 命中后停止（走同一串行路径，避免与 captureQueue 竞争）。
            captureQueue.async { [weak self] in self?.setDesired(false) }
        }
    }
}
