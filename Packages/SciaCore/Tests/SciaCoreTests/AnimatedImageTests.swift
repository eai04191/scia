import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

struct AnimatedImageTests {
    /// 1色で塗った`size`の正方形。
    private func square(_ size: Int, gray: CGFloat) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try #require(context.makeImage())
    }

    /// `delays`の秒数のコマを並べた、`type`の動く画像のデータ。コマごとに色を変える。
    private func animation(_ type: UTType, size: Int = 32, delays: [Double]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, try square(size, gray: CGFloat(index) / CGFloat(delays.count)), properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func splitsGIFIntoFramesWithTheirDurations() throws {
        let image = try #require(AnimatedImage.decode(animation(.gif, delays: [0.05, 0.2, 0.5]), maxPixelSize: 96))

        #expect(image.durations == [0.05, 0.2, 0.5])
        #expect(abs(image.duration - 0.75) < 0.0001)
        #expect(image.frameWidth == 32 && image.frameHeight == 32)
    }

    /// コマは、1枚の画像に左上から行ごとに、2pxのすき間を空けて並べる。5コマなら3列2行で、`contentsRect`はそのコマの部分だけを指す。
    @Test func arrangesFramesInSheetFromTopLeft() throws {
        let image = try #require(AnimatedImage.decode(animation(.gif, size: 10, delays: Array(repeating: 0.1, count: 5)), maxPixelSize: 96))

        #expect(image.columns == 3)
        #expect(image.sheet.width == 34 && image.sheet.height == 22)
        #expect(image.contentsRect(ofFrame: 0) == CGRect(x: 0, y: 0, width: 10.0 / 34, height: 10.0 / 22))
        #expect(image.contentsRect(ofFrame: 4) == CGRect(x: 12.0 / 34, y: 12.0 / 22, width: 10.0 / 34, height: 10.0 / 22))
        // コマごとに明るさを変えて塗っているので、上の行の左端は1コマ目、下の行の2列目は5コマ目の明るさになる。
        let pixels = try rgba(image.sheet)
        func pixel(x: Int, y: Int) -> (gray: UInt8, alpha: UInt8) {
            let offset = (y * image.sheet.width + x) * 4
            return (pixels[offset], pixels[offset + 3])
        }
        #expect(pixel(x: 5, y: 5).gray < pixel(x: 17, y: 5).gray, "1コマ目は2コマ目より暗い")
        #expect(pixel(x: 17, y: 17).gray > pixel(x: 5, y: 17).gray, "5コマ目は4コマ目より明るい")
        #expect(pixel(x: 10, y: 5).alpha == 0 && pixel(x: 5, y: 10).alpha == 0, "コマのあいだは透明")
        #expect(pixel(x: 29, y: 17).alpha == 0, "6コマ目の場所は空いている")
    }

    /// `image`を、上の行から並べたRGBAのバイト列にする。
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    @Test func splitsAPNGIntoFrames() throws {
        let image = try #require(AnimatedImage.decode(animation(.png, delays: [0.1, 0.3]), maxPixelSize: 96))

        // APNGのコマの長さは単精度で持つため、ずれを許して比べる。
        #expect(zip(image.durations, [0.1, 0.3]).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(image.frameCount == 2)
    }

    /// 0秒や0.01秒のコマは、ブラウザと同じく0.1秒で出す。
    @Test func treatsTooShortDelaysAsTenthOfSecond() throws {
        let image = try #require(AnimatedImage.decode(animation(.gif, delays: [0, 0.01, 0.02]), maxPixelSize: 96))

        #expect(image.durations == [0.1, 0.1, 0.02])
    }

    @Test func shrinksFramesToMaxPixelSize() throws {
        let image = try #require(AnimatedImage.decode(animation(.gif, size: 200, delays: [0.1, 0.1]), maxPixelSize: 96))

        #expect(image.frameWidth == 96 && image.frameHeight == 96)
    }

    /// グレースケールの画像でも、並べた画像はRGBAで持つので、RGBAに直した大きさで上限を確かめる。
    /// 96pxのコマはRGBAで約36KBなので、230コマで8MBを超える。グレースケールのままなら約2MBで、上限に収まって見える。
    @Test func grayscaleFramesAreCountedAsRGBA() throws {
        let data = NSMutableData()
        let count = 230
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, count, nil))
        let space = CGColorSpaceCreateDeviceGray()
        for index in 0..<count {
            let context = try #require(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(CGColor(gray: CGFloat(index % 2), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        }
        #expect(CGImageDestinationFinalize(destination))

        #expect(AnimatedImage.decode(data as Data, maxPixelSize: 96) == nil)
    }

    /// 並べた画像は、すき間と空いたコマの分だけコマの合計より大きいので、並べた画像でも上限を確かめる。
    /// 96pxの225コマは、コマの合計が約7.9MBで上限に収まるが、15列15行にすき間を空けて並べると8MBを超える。
    @Test func sheetIncludingGuttersRespectsMemoryLimit() throws {
        #expect(try AnimatedImage.decode(animation(.gif, size: 96, delays: Array(repeating: 0.1, count: 225)), maxPixelSize: 96) == nil)
    }

    /// 既定の画像がアニメーションに含まれないAPNGは、ImageIOが最初のコマを欠いて読むため、動かさずに静止画で描く。
    /// 最初の`fcTL`が`IDAT`の前にある、ふつうのAPNGは動かす。
    @Test func separateDefaultImageAPNGIsNotAnimated() throws {
        let normal = try animation(.png, delays: [0.1, 0.1])
        #expect(!AnimatedImage.hasSeparateDefaultImage(normal))
        #expect(AnimatedImage.decode(normal, maxPixelSize: 96) != nil)

        // 最初の`fcTL`を`IDAT`の後ろへ動かして、既定の画像を別にした形にする。チャンクの中身とCRCは確かめないので、並べ替えるだけでよい。
        let chunks = pngChunks(normal)
        let firstControl = try #require(chunks.firstIndex { $0.type == "fcTL" })
        let control = chunks[firstControl]
        var reordered = chunks
        reordered.remove(at: firstControl)
        let imageData = try #require(reordered.firstIndex { $0.type == "IDAT" })
        reordered.insert(control, at: imageData + 1)
        let separate = Data(normal.prefix(8)) + reordered.reduce(Data()) { $0 + $1.bytes }

        #expect(AnimatedImage.hasSeparateDefaultImage(separate))
        #expect(AnimatedImage.decode(separate, maxPixelSize: 96) == nil)
    }

    /// PNGのチャンクを、種類と、長さからCRCまでのバイト列で並べる。
    private func pngChunks(_ data: Data) -> [(type: String, bytes: Data)] {
        let bytes = [UInt8](data)
        var offset = 8
        var chunks: [(String, Data)] = []
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            chunks.append((String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self), Data(bytes[offset..<offset + 12 + length])))
            offset += 12 + length
        }
        return chunks
    }

    /// 1コマの画像は動かないので、静止画のまま描くためにnilを返す。
    @Test func returnsNilForStillImage() throws {
        #expect(try AnimatedImage.decode(animation(.png, delays: [0.1]), maxPixelSize: 96) == nil)
        #expect(AnimatedImage.decode(Data("not an image".utf8), maxPixelSize: 96) == nil)
    }

    /// 原寸が大きすぎる画像は、縮める前の展開でメモリを使いすぎるため、展開せずに断る。
    @Test func returnsNilWhenSourceIsTooLarge() throws {
        let data = try animation(.gif, size: 1025, delays: [0.1, 0.1])

        #expect(AnimatedImage.decode(data, maxPixelSize: 96) == nil)
        #expect(try AnimatedImage.decode(animation(.gif, size: 1024, delays: [0.1, 0.1]), maxPixelSize: 96) != nil)
    }

    /// 展開すると上限を超える画像は、動かさずに静止画で描く。96pxのコマは1枚約36KBなので、300コマで上限を超える。
    @Test func returnsNilWhenFramesExceedMemoryLimit() throws {
        let data = try animation(.gif, size: 96, delays: Array(repeating: 0.1, count: 300))

        #expect(AnimatedImage.decode(data, maxPixelSize: 96) == nil)
    }
}
