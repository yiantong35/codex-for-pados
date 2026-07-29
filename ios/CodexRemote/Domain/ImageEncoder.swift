import UIKit

/// F7：图片发送前有界编码的结果。`.tooLarge` 携带实测字节数与上限，供 UI 提示具体数字。
enum ImageEncodeResult {
    case ok(dataURL: String, bytes: Int)
    case tooLarge(bytes: Int, limit: Int)
}

/// 后台（非主 actor）降采样 + 迭代降质编码，杜绝全尺寸原图 base64 撑爆 relay 单帧上限致断连。
///
/// relay 单帧上限见 `relay-server/Sources/RelayServerCore/FrameAccumulator.swift:8`
/// （`1 << 20` = 1 MiB）；iOS 侧不能 `import RelayServerCore`，故在此镜像该常量。
/// data URL 文本（base64 编码后的密文体积 ≈ 明文体积）受 ws text frame 该上限约束，
/// 留 `envelopeHeadroom` 给 JSON-RPC envelope 包装余量。
enum ImageEncoder {
    /// 镜像 relay-server `FrameAccumulator.swift:8` 的单帧上限。
    static let relayMaxMessageBytes = 1 << 20
    /// JSON-RPC envelope 包装余量。
    static let envelopeHeadroom = 64 * 1024
    /// 降采样目标最长边（像素）。
    static let maxLongestEdge: CGFloat = 1568
    /// data URL 文本字节数上限（=relay 单帧上限 - envelope 余量）。
    static var byteLimit: Int { relayMaxMessageBytes - envelopeHeadroom }

    /// 后台降采样 + 迭代降质编码；返回可发送的 data URL 或带具体字节数的超限拒绝。
    /// 全程在 `Task.detached`（非主 actor）内完成，避免大图解码/编码阻塞 UI。
    static func encodeForSend(_ raw: Data) async -> ImageEncodeResult {
        await Task.detached(priority: .userInitiated) {
            guard let img = UIImage(data: raw) else {
                return ImageEncodeResult.tooLarge(bytes: raw.count, limit: byteLimit)
            }
            let scaled = downscale(img, longestEdge: maxLongestEdge)
            var lastBytes = 0
            for qTenth in stride(from: 7, through: 3, by: -1) {
                let quality = CGFloat(qTenth) / 10
                guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
                let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                lastBytes = dataURL.utf8.count
                if lastBytes <= byteLimit {
                    return .ok(dataURL: dataURL, bytes: lastBytes)
                }
            }
            return .tooLarge(bytes: lastBytes, limit: byteLimit)
        }.value
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
