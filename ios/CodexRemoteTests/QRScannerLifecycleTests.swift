import XCTest
@testable import CodexRemote

/// #4：扫码相机启停串行化。模拟器无相机，故只测**纯对齐决策**（不实际起相机）——
/// 目标态（desiredRunning）与实际运行态经 `reconcile` 收敛，验证「stop 无条件、最终态收敛到停止」不变量。
final class QRScannerLifecycleTests: XCTestCase {
    func testPreviewRotationTracksAllInterfaceOrientations() {
        XCTAssertEqual(QRScannerView.PreviewView.rotationAngle(for: .portrait), 90)
        XCTAssertEqual(QRScannerView.PreviewView.rotationAngle(for: .portraitUpsideDown), 270)
        XCTAssertEqual(QRScannerView.PreviewView.rotationAngle(for: .landscapeLeft), 0)
        XCTAssertEqual(QRScannerView.PreviewView.rotationAngle(for: .landscapeRight), 180)
        XCTAssertNil(QRScannerView.PreviewView.rotationAngle(for: .unknown))
    }

    /// 目标态 = 停止：无论当前是否在跑，最终决策要么停要么无操作，绝不 start。
    func test_reconcile_desired_stop_never_starts() {
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: false, isRunning: true), .stop)
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: false, isRunning: false), .noop)
    }

    /// 目标态 = 运行：未跑则启动，已跑则无操作（幂等）。
    func test_reconcile_desired_start() {
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: true, isRunning: false), .start)
        XCTAssertEqual(QRScannerView.PreviewView.reconcile(desired: true, isRunning: true), .noop)
    }

    /// 关键回归锚（dismantle 后 stop）：先 start 再 stop 的目标态序列，最终目标态=停止 → 决策绝不是 start。
    func test_start_then_stop_converges_to_stop() {
        // 模拟串行队列按序应用：start 设 desired=true，stop 设 desired=false（最后一次为准）。
        var desired = false
        desired = true                      // start()
        desired = false                     // stop()（无条件，不早退）
        XCTAssertNotEqual(QRScannerView.PreviewView.reconcile(desired: desired, isRunning: false), .start)
    }
}
