import XCTest
import UIKit

private final class PerceptualSnapshotBundleToken: NSObject {}

enum PerceptualSnapshot {
    private static let side = 32
    private static let meanDeltaLimit = 0.025
    private static let changedPixelFractionLimit = 0.08
    private static let significantDelta: UInt8 = 24

    static func assert(_ png: Data, named name: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let expected = baselines[name],
              let expectedData = Data(base64Encoded: expected) else {
            XCTFail("Missing perceptual baseline \(name). Actual: \(fingerprint(png).base64EncodedString())",
                    file: file, line: line)
            return
        }
        let actual = fingerprint(png)
        guard actual.count == expectedData.count, actual.count == side * side else {
            XCTFail("Invalid perceptual baseline \(name). Actual: \(actual.base64EncodedString())",
                    file: file, line: line)
            return
        }

        let differences = zip(actual, expectedData).map { abs(Int($0) - Int($1)) }
        let meanDelta = Double(differences.reduce(0, +)) / Double(differences.count * 255)
        let changedFraction = Double(differences.filter { $0 > significantDelta }.count)
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
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return Data(pixels)
    }
}
