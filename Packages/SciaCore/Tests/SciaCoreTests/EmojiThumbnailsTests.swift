import CoreGraphics
import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
struct EmojiThumbnailsTests {
    private let file = TestScratch.url("EmojiThumbnailsTests").appending(path: "thumbnails.bin")

    private func url(_ name: String) throws -> URL {
        try #require(URL(string: "https://files.example.social/custom_emojis/\(name)"))
    }

    private static func image(width: Int, height: Int, red: CGFloat) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// 足した画像は高さをそろえて縮めて持ち、起動し直しても、ファイルから引ける。
    @Test func keepsScaledImagesAcrossInstances() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        thumbnails.add(try url("wide.png"), image: try Self.image(width: 384, height: 96, red: 0.5))
        await thumbnails.flush()
        #expect(thumbnails.image(for: try url("a.png"))?.height == 16)

        let next = EmojiThumbnails(file: file, pixelHeight: 16)
        #expect(next.image(for: try url("a.png")) == nil, "読み込む前は引けない")
        next.load()

        let a = try #require(next.image(for: try url("a.png")))
        #expect((a.width, a.height) == (16, 16))
        let wide = try #require(next.image(for: try url("wide.png")))
        #expect((wide.width, wide.height) == (64, 16))
        #expect(next.image(for: try url("missing.png")) == nil)
    }

    /// 画素はLZ4で圧縮して書く。単色の画像なら、展開した画素よりずっと小さいファイルになり、読み直しても同じ画素に戻る。
    @Test func storesCompressedPixels() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 32)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()

        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size < 32 * 32 * 4 / 4)
        let reloaded = EmojiThumbnails(file: file, pixelHeight: 32)
        reloaded.load()
        let image = try #require(reloaded.image(for: try url("a.png")))
        let pixel = try #require(image.dataProvider?.data as Data?)
        #expect(pixel.count == 32 * 32 * 4)
        #expect(pixel.prefix(4) == Data([255, 0, 0, 255]))
    }

    /// 高さを変えたら、前のファイルは使わずに作り直す。
    @Test func discardsFileOfDifferentHeight() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()

        let taller = EmojiThumbnails(file: file, pixelHeight: 24)
        taller.load()
        #expect(taller.image(for: try url("a.png")) == nil)
        taller.add(try url("b.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await taller.flush()

        let reloaded = EmojiThumbnails(file: file, pixelHeight: 24)
        reloaded.load()
        #expect(reloaded.image(for: try url("b.png"))?.height == 24)
        #expect(reloaded.image(for: try url("a.png")) == nil)
    }

    /// リストにないものを消して書き直す。残したものは、起動し直しても引ける。
    @Test func prunesUnlistedImages() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        for name in ["a.png", "b.png", "c.png"] {
            thumbnails.add(try url(name), image: try Self.image(width: 96, height: 96, red: 1))
        }
        await thumbnails.flush()

        await thumbnails.prune(keeping: [try url("b.png")])

        #expect(thumbnails.image(for: try url("a.png")) == nil)
        #expect(thumbnails.image(for: try url("b.png")) != nil)
        let reloaded = EmojiThumbnails(file: file, pixelHeight: 16)
        reloaded.load()
        #expect(reloaded.count == 1)
        #expect(reloaded.image(for: try url("b.png"))?.height == 16)
    }

    /// 全部消すと、ファイルも消える。消したあとも足せる。
    @Test func removesAll() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()

        await thumbnails.removeAll()

        #expect(thumbnails.image(for: try url("a.png")) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        thumbnails.add(try url("b.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()
        let reloaded = EmojiThumbnails(file: file, pixelHeight: 16)
        reloaded.load()
        #expect(reloaded.count == 1)
    }

    /// 途切れた記録のあとに足しても、途切れた分を切り詰めてから書き足すので、起動し直しても前の記録と足した記録を引ける。
    @Test func appendsAfterTruncatedRecord() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        thumbnails.add(try url("b.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()
        let data = try Data(contentsOf: file)
        try data.prefix(data.count - 10).write(to: file)

        let next = EmojiThumbnails(file: file, pixelHeight: 16)
        next.load()
        next.add(try url("c.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await next.flush()

        let reloaded = EmojiThumbnails(file: file, pixelHeight: 16)
        reloaded.load()
        #expect(reloaded.image(for: try url("a.png")) != nil)
        #expect(reloaded.image(for: try url("c.png")) != nil)
    }

    /// 全部消す前に始めた作業の画像は、消したあとに足さない。消したものを戻さないため。
    @Test func dropsImagesStartedBeforeRemoval() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        let generation = thumbnails.generation

        await thumbnails.removeAll()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1), generation: generation)
        await thumbnails.flush()

        #expect(thumbnails.image(for: try url("a.png")) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// 幅を高さの8倍で止めるときは、縦横の比を保って高さも縮める。
    @Test func keepsAspectRatioOfVeryWideImages() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 32)
        thumbnails.load()

        thumbnails.add(try url("wide.png"), image: try Self.image(width: 2_048, height: 128, red: 1))
        await thumbnails.flush()

        let image = try #require(thumbnails.image(for: try url("wide.png")))
        #expect((image.width, image.height) == (256, 16))
    }

    /// 書きかけで途切れた記録は使わず、その前までの記録は使う。
    @Test func ignoresTruncatedRecord() async throws {
        let thumbnails = EmojiThumbnails(file: file, pixelHeight: 16)
        thumbnails.load()
        thumbnails.add(try url("a.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()
        thumbnails.add(try url("b.png"), image: try Self.image(width: 96, height: 96, red: 1))
        await thumbnails.flush()
        let data = try Data(contentsOf: file)
        try data.prefix(data.count - 10).write(to: file)

        let reloaded = EmojiThumbnails(file: file, pixelHeight: 16)
        reloaded.load()

        #expect(reloaded.image(for: try url("a.png")) != nil)
        #expect(reloaded.image(for: try url("b.png")) == nil)
    }
}
