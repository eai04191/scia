import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

struct ImageDecoderTests {
    /// 幅`width`、高さ`height`のPNG。`orientation`を付けると、EXIFの向きとして書く。
    private func png(width: Int, height: Int, orientation: CGImagePropertyOrientation? = nil) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0.rawValue] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test(arguments: [ImageDecoder.DynamicRange.high, .standard])
    func shrinksTheLongSideToTheLimit(dynamicRange: ImageDecoder.DynamicRange) throws {
        let image = try #require(ImageDecoder.thumbnail(of: try png(width: 400, height: 100), maxPixelSize: 96, dynamicRange: dynamicRange))
        #expect(image.width == 96)
        #expect(image.height == 24)
    }

    /// 限りより小さい画像は、拡大しない。
    @Test func doesNotEnlargeSmallImages() throws {
        let image = try #require(ImageDecoder.thumbnail(of: try png(width: 40, height: 20), maxPixelSize: 96, dynamicRange: .high))
        #expect(image.width == 40)
        #expect(image.height == 20)
    }

    /// 向きを画素に反映する。
    @Test func appliesOrientation() throws {
        let image = try #require(ImageDecoder.thumbnail(of: try png(width: 40, height: 20, orientation: .right), maxPixelSize: 96, dynamicRange: .standard))
        #expect(image.width == 20)
        #expect(image.height == 40)
    }

    /// 行の高さに合わせて描く絵文字は、高さで縮める大きさを決める。横長でも高さが足りるように長い辺を伸ばし、伸ばすのは高さの8倍まで。
    @Test(arguments: [(400, 100, 384), (100, 400, 96), (50, 50, 96), (2000, 100, 768)])
    func maxPixelSizeKeepsTheHeight(width: Int, height: Int, expected: Int) throws {
        #expect(ImageDecoder.maxPixelSize(forHeight: 96, of: try png(width: width, height: height)) == expected)
    }

    @Test func maxPixelSizeFollowsOrientation() throws {
        #expect(ImageDecoder.maxPixelSize(forHeight: 96, of: try png(width: 100, height: 400, orientation: .right)) == 384)
    }

    @Test func returnsNilForDataThatIsNotAnImage() {
        #expect(ImageDecoder.thumbnail(of: Data("<html>503</html>".utf8), maxPixelSize: 96, dynamicRange: .high) == nil)
    }
}
