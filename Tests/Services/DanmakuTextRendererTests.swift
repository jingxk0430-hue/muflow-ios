import UIKit
import XCTest
@testable import MuFlow

final class DanmakuTextRendererTests: XCTestCase {
    @MainActor
    func testOutlinePreservesSolidChineseAndLatinFill() throws {
        let plain = DanmakuTextRenderer.image("弹幕清晰 Aa 123", fontSize: 20, outline: 0, scale: 3)
        let outlined = DanmakuTextRenderer.image("弹幕清晰 Aa 123", fontSize: 20, outline: 0.65, scale: 3)
        let baseline = try countPixels(plain) { $0 > 210 && $1 > 210 && $2 > 210 && $3 > 210 }
        let result = try countPixels(outlined) { $0 > 210 && $1 > 210 && $2 > 210 && $3 > 210 }
        XCTAssertGreaterThan(baseline, 500, "The actual glyph interiors must be filled")
        XCTAssertGreaterThanOrEqual(Double(result), Double(baseline) * 0.9,
                                    "A black outline must not hollow out or erase white strokes")
    }

    @MainActor
    func testColoredCommentsKeepTheirFillAndNativeResolution() throws {
        let image = DanmakuTextRenderer.image("你好 Hello", color: 0xFF0000, fontSize: 20, outline: 0.65, scale: 3)
        let pixels = try countPixels(image) { $0 > 210 && $1 < 30 && $2 < 30 && $3 > 210 }
        XCTAssertGreaterThan(pixels, 500)
        let bitmap = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(bitmap.width, Int(image.size.width * 3))
        XCTAssertEqual(bitmap.height, Int(image.size.height * 3))
    }

    private func countPixels(_ image: UIImage, matching: (UInt8, UInt8, UInt8, UInt8) -> Bool) throws -> Int {
        let bitmap = try XCTUnwrap(image.cgImage)
        let width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                    CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            matching(bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3])
        }.count
    }
}
