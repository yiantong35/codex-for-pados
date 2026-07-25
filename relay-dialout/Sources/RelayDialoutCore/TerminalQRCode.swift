import Foundation
import CoreImage

/// 终端二维码渲染：把配对载荷字符串（codexrelay:// URL）渲染成半块字符 ASCII 二维码，
/// 供开发机终端直接扫码；同时调用方仍保留 URL 明文打印作兜底（不支持扫码的终端也能手动搬运）。
public enum TerminalQRCode {
    public enum QRError: Error {
        case generationFailed
    }

    /// 生成 QR 布尔矩阵（true = 黑模块）。CIQRCodeGenerator 每个模块输出 1px，方阵。
    public static func matrix(for text: String) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw QRError.generationFailed }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { throw QRError.generationFailed }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw QRError.generationFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            throw QRError.generationFailed
        }
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)

        var rows: [[Bool]] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            var row: [Bool] = []
            row.reserveCapacity(width)
            for x in 0..<width {
                let luminance = ptr[y * bytesPerRow + x * bytesPerPixel]
                row.append(luminance < 128)   // 灰度低 = 黑模块
            }
            rows.append(row)
        }
        return rows
    }

    /// 半块字符渲染：一个字符高度覆盖两行像素模块（▀ 上黑 / ▄ 下黑 / █ 全黑 / 空格全白），
    /// 四周补 quiet zone（静默区）保证扫码识别率。
    public static func halfBlockString(for text: String, quiet: Int = 2) throws -> String {
        let raw = try matrix(for: text)
        let innerWidth = raw.first?.count ?? 0
        let width = innerWidth + quiet * 2
        let blankRow = [Bool](repeating: false, count: width)

        var padded = raw.map { row in
            [Bool](repeating: false, count: quiet) + row + [Bool](repeating: false, count: quiet)
        }
        let quietRows = [[Bool]](repeating: blankRow, count: quiet)
        padded = quietRows + padded + quietRows

        var out = ""
        var y = 0
        while y < padded.count {
            for x in 0..<width {
                let top = padded[y][x]
                let bottom = (y + 1 < padded.count) ? padded[y + 1][x] : false
                if top && bottom {
                    out += "█"
                } else if top {
                    out += "▀"
                } else if bottom {
                    out += "▄"
                } else {
                    out += " "
                }
            }
            out += "\n"
            y += 2
        }
        return out
    }
}
