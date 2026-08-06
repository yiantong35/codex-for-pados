import UIKit
import RelayProtocol

/// F7：图片发送前有界编码的结果。`.tooLarge` 携带实测字节数与上限，供 UI 提示具体数字。
enum ImageEncodeResult: Sendable {
    case ok(dataURL: String, bytes: Int)
    case tooLarge(bytes: Int, limit: Int)
    case cancelled
}

/// 后台（非主 actor）降采样 + 迭代降质编码，杜绝全尺寸原图 base64 撑爆 relay 单帧上限致断连。
///
/// relay 单帧上限见 `relay-server/Sources/RelayServerCore/FrameAccumulator.swift:8`
/// （`1 << 20` = 1 MiB）；iOS 侧不能 `import RelayServerCore`，故在此镜像该常量。
///
/// 关键：`byteLimit` 约束的是**明文** data URL，但明文并非直接上线——它先经 E2E
/// 加密，密文体再由 JSONEncoder base64（×4/3）打进单帧。故明文预算必须留出这层
/// 膨胀：`明文上限 ≈ 帧上限 / (4/3) − envelope`（≈ 帧上限的 ¾）。若按帧上限直接
/// 卡明文，近上限图片密文化后 ≈1.3 MiB 会撑爆 1 MiB 帧上限致 relay 断连。
enum ImageEncoder {
    /// 三端共享的 relay 单帧上限。
    static let relayMaxMessageBytes = RelayWireLimits.maxMessageBytes
    /// JSON-RPC envelope 包装余量。
    static let envelopeHeadroom = 64 * 1024
    /// 降采样目标最长边（像素）。
    static let maxLongestEdge: CGFloat = 1568
    /// 明文 data URL 文本字节数上限。密文经 base64 膨胀 ×4/3 进单帧，故按帧上限的
    /// ¾ 折算再扣 envelope 余量，确保加密上线后仍 < relay 单帧上限（#5）。
    static var byteLimit: Int { Int(Double(relayMaxMessageBytes) * 3.0 / 4.0) - envelopeHeadroom }

    /// 后台降采样 + 迭代降质编码；返回可发送的 data URL 或带具体字节数的超限拒绝。
    /// 全程在 `Task.detached`（非主 actor）内完成，避免大图解码/编码阻塞 UI。
    static func encodeForSend(
        _ raw: Data,
        onStage: (@Sendable (Int) -> Void)? = nil
    ) async -> ImageEncodeResult {
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return ImageEncodeResult.cancelled }
            guard let img = UIImage(data: raw) else {
                return ImageEncodeResult.tooLarge(bytes: raw.count, limit: byteLimit)
            }
            onStage?(0)
            guard !Task.isCancelled else { return .cancelled }
            let scaled = downscale(img, longestEdge: maxLongestEdge)
            onStage?(1)
            guard !Task.isCancelled else { return .cancelled }
            var lastBytes = 0
            for qTenth in stride(from: 7, through: 3, by: -1) {
                guard !Task.isCancelled else { return .cancelled }
                let quality = CGFloat(qTenth) / 10
                guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
                onStage?(qTenth)
                guard !Task.isCancelled else { return .cancelled }
                let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                lastBytes = dataURL.utf8.count
                if lastBytes <= byteLimit {
                    return .ok(dataURL: dataURL, bytes: lastBytes)
                }
            }
            return .tooLarge(bytes: lastBytes, limit: byteLimit)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// 最长边超出 `longestEdge` 时等比缩小；否则原样返回（不放大小图）。
    private static func downscale(_ img: UIImage, longestEdge: CGFloat) -> UIImage {
        let width = img.size.width
        let height = img.size.height
        let longest = max(width, height)
        guard longest > longestEdge else { return img }
        let scale = longestEdge / longest
        let target = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
