import XCTest
import UIKit

private final class PerceptualSnapshotBundleToken: NSObject {}

enum PerceptualSnapshot {
    private static let recording = false
    private static let side = 64
    private static let channels = 4
    private static let meanDeltaLimit = 0.012
    private static let changedPixelFractionLimit = 0.035
    private static let significantDelta: UInt8 = 18

    static func assert(_ png: Data, named name: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let actual = fingerprint(png)
        if recording {
            let path = "/tmp/uiux-baseline-\(name).txt"
            try? actual.base64EncodedString().write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = baselines[name],
              let expectedData = Data(base64Encoded: expected) else {
            XCTFail("Missing perceptual baseline \(name). Actual: \(actual.base64EncodedString())",
                    file: file, line: line)
            return
        }
        guard actual.count == expectedData.count, actual.count == side * side * channels else {
            XCTFail("Invalid perceptual baseline \(name). Actual: \(actual.base64EncodedString())",
                    file: file, line: line)
            return
        }

        let differences = stride(from: 0, to: actual.count, by: channels).map {
            let red = abs(Int(actual[$0]) - Int(expectedData[$0]))
            let green = abs(Int(actual[$0 + 1]) - Int(expectedData[$0 + 1]))
            let blue = abs(Int(actual[$0 + 2]) - Int(expectedData[$0 + 2]))
            return max(red, green, blue)
        }
        let meanDelta = Double(differences.reduce(0, +)) / Double(differences.count * 255)
        let changedFraction = Double(differences.filter { $0 > Int(significantDelta) }.count)
            / Double(differences.count)
        XCTAssertLessThanOrEqual(meanDelta, meanDeltaLimit,
            "Visual regression \(name): mean delta \(meanDelta). Actual: \(actual.base64EncodedString())",
            file: file, line: line)
        XCTAssertLessThanOrEqual(changedFraction, changedPixelFractionLimit,
            "Visual regression \(name): changed fraction \(changedFraction). Actual: \(actual.base64EncodedString())",
            file: file, line: line)
    }

    private static var baselines: [String: String] {
        guard let url = Bundle(for: PerceptualSnapshotBundleToken.self)
            .url(forResource: "VisualBaselines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    private static func fingerprint(_ png: Data) -> Data {
        guard let image = UIImage(data: png)?.cgImage else { return Data() }
        var pixels = [UInt8](repeating: 0, count: side * side * channels)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * channels,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return Data(pixels)
    }
}
