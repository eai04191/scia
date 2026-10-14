import Testing
import UIKit
@testable import Scia

/// 閉じる動きで下地に開ける穴の形を確かめる。
@MainActor
struct MediaClosingFlightTests {
    /// 左半分が不透明、右半分が透明な画像。
    private func halfTransparentImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
    }

    private func alpha(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    /// 透明度を持たない画像は、穴を開けきるため反転した画像を作らない。
    @Test func opaqueImageHasNoInverseAlpha() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { _ in }
        #expect(MediaClosingFlight.inverseAlphaImage(of: image) == nil)
    }

    /// 透明な部分は下地を残すため不透明に、不透明な部分は穴にするため透明にする。
    @Test func transparentPartsBecomeOpaque() throws {
        let inverse = try #require(MediaClosingFlight.inverseAlphaImage(of: halfTransparentImage()))
        #expect(try alpha(of: inverse, x: 10, y: 25) == 0)
        #expect(try alpha(of: inverse, x: 90, y: 25) == 255)
    }
}
