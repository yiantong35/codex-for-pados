import XCTest
import UIKit
import RelayProtocol
@testable import CodexRemote

/// F7：图片发送前有界编码。relay 单帧上限 1 MiB（镜像 relay-server
/// `FrameAccumulator.swift:8`）；普通照片全尺寸 base64 后远超此限会致 relay 断连。
/// 覆盖：大图降采样落上限内 / 无法落入上限时带具体数字拒绝 / 非 JPEG 原图重编码后如实标注 MIME。
final class ImageEncoderTests: XCTestCase {

    func test_relay_limit_comes_from_shared_protocol_contract() {
        XCTAssertEqual(ImageEncoder.relayMaxMessageBytes, RelayWireLimits.maxMessageBytes)
    }

    func test_large_image_downscaled_within_limit() async throws {
        let big = Self.makeTestJPEG(width: 4032, height: 3024)
        let r = await ImageEncoder.encodeForSend(big)
        guard case .ok(let url, let bytes) = r else { return XCTFail("应成功编码") }
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"), "MIME 应反映真实编码格式")
        XCTAssertLessThanOrEqual(bytes, ImageEncoder.byteLimit)
    }

    func test_untohandleably_large_rejected_with_numbers() async throws {
        // 高熵噪声图直接生成在降采样目标尺寸（1568×1568，最长边==maxLongestEdge，encodeForSend
        // 不再降采样），避免途经降采样插值抹平高频噪声、削弱可靠性；实测该尺寸真随机噪声在
        // JPEG 质量 0.3 时 dataURL 仍 ~1.15MB > 983KB 上限，margin 充足可靠触发 tooLarge。
        let noise = Self.makeHighEntropyJPEG(width: 1568, height: 1568)
        let r = await ImageEncoder.encodeForSend(noise)
        guard case .tooLarge(let bytes, let limit) = r else { return XCTFail("应拒绝并带数字") }
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(limit, ImageEncoder.byteLimit)
    }

    func test_png_input_reencoded_and_labeled_jpeg() async throws {
        let png = Self.makeTestPNG(width: 800, height: 600)
        let r = await ImageEncoder.encodeForSend(png)
        guard case .ok(let url, _) = r else { return XCTFail("应成功编码") }
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"), "PNG 原图应被重编码为 JPEG 并如实标注")
    }

    /// #5：`byteLimit` 是明文 dataURL 的接受上界，但明文并非直接上线——它先经
    /// AES-GCM 加密（+16 字节 tag），再由 JSONEncoder 将密文体 base64（×4/3）打进单帧。
    /// 故一张恰好落在 `byteLimit` 的图，其真实上线帧 ≈ `明文 × 4/3 + envelope`，
    /// 必须仍 < relay 单帧上限，否则近上限图片将撑爆 1 MiB 帧上限致 relay 断连。
    /// 断言字节换算：现行 `byteLimit = 帧上限 − envelope` 过宽 → 该帧超限（RED）。
    func test_byteLimit_survives_encryption_base64_within_relay_frame() {
        let worstPlaintext = ImageEncoder.byteLimit
        // 密文体 = 明文 UTF-8 + 16 字节 GCM tag；JSONEncoder base64 后 = 4·⌈n/3⌉。
        let base64Body = 4 * Int(ceil(Double(worstPlaintext + 16) / 3.0))
        let projectedFrame = base64Body + ImageEncoder.envelopeHeadroom
        XCTAssertLessThanOrEqual(
            projectedFrame, ImageEncoder.relayMaxMessageBytes,
            "明文上限图片经加密+base64 后应仍 < relay 单帧上限"
            + "（projected=\(projectedFrame) vs cap=\(ImageEncoder.relayMaxMessageBytes)）")
    }

    func test_cancellation_reaches_detached_multistage_encoder() async throws {
        let reachedStage = expectation(description: "encoder reached compression stage")
        let resumeStage = DispatchSemaphore(value: 0)
        let image = Self.makeTestJPEG(width: 2000, height: 1600)
        let task = Task {
            await ImageEncoder.encodeForSend(image) { stage in
                guard stage == 1 else { return }
                reachedStage.fulfill()
                resumeStage.wait()
            }
        }

        await fulfillment(of: [reachedStage], timeout: 2)
        task.cancel()
        resumeStage.signal()
        let result = await task.value
        guard case .cancelled = result else {
            return XCTFail("取消必须传播到 detached 编码任务")
        }
    }

    // MARK: - Test image helpers

    /// 纯色测试图，编码为 JPEG（模拟全尺寸照片，尺寸大但内容简单，仍应能落入预算）。
    static func makeTestJPEG(width: Int, height: Int) -> Data {
        let img = renderImage(width: width, height: height) { ctx, size in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.9)!
    }

    /// 高熵随机噪声图，编码为 JPEG——逐像素真随机（`arc4random_buf` 直接灌满整块像素缓冲区，
    /// 毫秒级完成、避免逐像素/逐块 CGContext 绘制调用在百万级迭代下过慢），JPEG 结构性地
    /// 难以压缩，用于可靠触发 tooLarge（实测 1568×1568 @ quality 0.3 dataURL 仍超上限约 17%）。
    static func makeHighEntropyJPEG(width: Int, height: Int) -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        buffer.withUnsafeMutableBytes { raw in
            arc4random_buf(raw.baseAddress, raw.count)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            fatalError("构造噪声图失败")
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)!
    }

    /// 纯色测试图，编码为 PNG（用于验证非 JPEG 原图被重编码后如实标注 MIME）。
    static func makeTestPNG(width: Int, height: Int) -> Data {
        let img = renderImage(width: width, height: height) { ctx, size in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.pngData()!
    }

    private static func renderImage(
        width: Int, height: Int, draw: (CGContext, CGSize) -> Void
    ) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            draw(ctx.cgContext, size)
        }
    }
}
