import CoreGraphics
import Foundation
import ImageIO
import SciaTesting
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

@MainActor
struct EmojiImageStoreTests {
    private let url = URL(string: "https://example.com/emoji.png")!
    private let fetches = FetchCounter()

    private final class FetchCounter: Sendable {
        let count = Mutex(0)
    }

    /// - Parameter upgradePurpose: 持っている画像より高く読み直す通信の目的。nilなら、質を上げる通信を送れない回線として扱う。
    private func makeStore(_ data: Data, upgradePurpose: RequestPurpose? = .enhancement(onExpensiveNetwork: false)) -> EmojiImageStore<CGImage> {
        EmojiImageStore(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { upgradePurpose }
        ) { [fetches] _ in
            fetches.count.withLock { $0 += 1 }
            return data
        }
    }

    /// 1色で塗った`width`×`height`の画像。
    private static func image(width: Int, height: Int, gray: CGFloat = 0.5) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width, height: height), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `frameCount`コマの、`size`四方のGIF。コマごとに明るさを変える。
    private static func gif(size: Int, frameCount: Int) throws -> Data {
        try gif(width: size, height: size, frameCount: frameCount)
    }

    private static func gif(width: Int, height: Int, frameCount: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil))
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for index in 0..<frameCount {
            CGImageDestinationAddImage(destination, try image(width: width, height: height, gray: CGFloat(index) / CGFloat(frameCount)), properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 既定より大きく描くと、そのURLを描く高さで読み直す。読み終えるまでは前の画像を返し、読み終えたら、小さく描く場所にも同じ1枚を返す。
    @Test func reloadsAtLargerHeightAndKeepsOneImagePerURL() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400))
        #expect(store.image(for: url) == nil)
        try await waitUntil { store.image(for: url) != nil }
        let small = try #require(store.image(for: url))
        #expect(small.height == 96)

        #expect(store.image(for: url, pixelHeight: 200)?.height == 96, "読み直している間は、前の画像で描く")
        try await waitUntil { store.loading.isEmpty }
        #expect(store.image(for: url, pixelHeight: 200)?.height == 200)
        #expect(store.image(for: url)?.height == 200, "小さく描く場所も、同じ1枚を縮めて描く")
        #expect(store.loading.isEmpty, "持っている画像より低く描くときは読み直さない")
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 元の画像が求めた高さより小さければ、元の大きさで読み、それより高く描くことになっても読み直さない。拡大しても、ぼけは消えないため。
    @Test func doesNotReloadBeyondSourceSize() async throws {
        let store = makeStore(try Self.png(width: 128, height: 128))
        _ = store.image(for: url, pixelHeight: 300)
        try await waitUntil { store.loading.isEmpty && store.image(for: url, pixelHeight: 300) != nil }
        #expect(store.image(for: url, pixelHeight: 300)?.height == 128)

        _ = store.image(for: url, pixelHeight: 600)
        #expect(store.loading.isEmpty)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    /// 動く絵文字を大きく描くと読み直し、その高さでは`AnimatedImage.maxByteCount`を超えるなら、動きを止めずに、収まる中で一番高く読む。
    /// それより高く描くことになっても、同じ上限に当たるので読み直さない。
    @Test func reloadsAnimationAtLargestHeightWithinByteLimit() async throws {
        let store = makeStore(try Self.gif(size: 512, frameCount: 20))
        #expect(store.animation(for: url) == nil)
        try await waitUntil { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 96)

        let previous = try #require(store.animation(for: url))
        #expect(store.animation(for: url, pixelHeight: 1_000) === previous, "読み直している間は、前のコマで動かす")
        try await waitUntil { store.upgradingAnimations.isEmpty }
        let enlarged = try #require(store.animation(for: url, pixelHeight: 1_000)).image
        // 512pxのまま20コマ並べると約20MBで超えるので、収まる高さまで下げる。
        #expect(enlarged.frameHeight > 96 && enlarged.frameHeight < 512)
        #expect(enlarged.sheet.width * enlarged.sheet.height * 4 <= AnimatedImage.maxByteCount)

        _ = store.animation(for: url, pixelHeight: 2_000)
        #expect(store.upgradingAnimations.isEmpty)
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 質を上げる通信を送れない回線では、持っている画像より高く読み直さず、持っている画像を拡大して描く。
    /// 初めて読むときは、大きく描くための高さでも通信は同じなので、その高さで読む。
    @Test func doesNotReloadWithoutEnhancementPurpose() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400), upgradePurpose: nil)
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }

        #expect(store.image(for: url, pixelHeight: 200)?.height == 96)
        #expect(store.loading.isEmpty)
        #expect(fetches.count.withLock { $0 } == 1)

        let other = URL(string: "https://example.com/other.png")!
        _ = store.image(for: other, pixelHeight: 200)
        try await waitUntil { store.image(for: other, pixelHeight: 200) != nil }
        #expect(store.image(for: other, pixelHeight: 200)?.height == 200)
    }

    /// 持っている画像の1.1倍（`upscaleTolerance`）までの高さなら、読み直さずに拡大して描く。初めて読むときも、既定の高さの1.1倍までなら既定の高さで読む。
    @Test func drawsWithinUpscaleToleranceWithoutReloading() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400))
        _ = store.image(for: url, pixelHeight: 105)
        try await waitUntil { store.image(for: url) != nil }
        #expect(store.image(for: url)?.height == 96, "105pxは96pxの1.1倍以内なので、既定の高さで読む")

        _ = store.image(for: url, pixelHeight: 106)
        try await waitUntil { store.loading.isEmpty }
        #expect(store.image(for: url)?.height == 106)
        _ = store.image(for: url, pixelHeight: 116)
        #expect(store.loading.isEmpty, "106pxの1.1倍（116.6px）までは読み直さない")
        _ = store.image(for: url, pixelHeight: 117)
        try await waitUntil { store.loading.isEmpty }
        #expect(store.image(for: url)?.height == 117)
        #expect(fetches.count.withLock { $0 } == 3)
    }

    /// とても大きく描くときも、静止画1枚は`maxStillPixelCount`に収まる高さで止める。1枚でキャッシュの上限を超えると、入れたそばから捨てられて読み直し続けるため。
    /// 止めたら、それより高く描くことになっても読み直さない。
    @Test func limitsStillToMaxPixelCount() async throws {
        let store = makeStore(try Self.png(width: 3_072, height: 3_072))
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }

        _ = store.image(for: url, pixelHeight: 3_456)
        try await waitUntil { store.loading.isEmpty }
        let image = try #require(store.image(for: url, pixelHeight: 3_456))
        #expect(image.width * image.height <= EmojiImageStore<CGImage>.maxStillPixelCount)
        #expect(image.height > 96)
        _ = store.image(for: url, pixelHeight: 4_000)
        #expect(store.loading.isEmpty)
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 極端に横長な画像は、幅の上限のために求めた高さより低く読むが、元の画像には余裕があるので、高く描くときは読み直す。
    @Test func reloadsWideStillLimitedByAspectRatio() async throws {
        let store = makeStore(try Self.png(width: 2_048, height: 128))
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        #expect(store.image(for: url)?.height == 48, "幅は高さの8倍の768pxで止めるので、高さは48px")

        _ = store.image(for: url, pixelHeight: 128)
        try await waitUntil { store.loading.isEmpty }
        #expect(store.image(for: url, pixelHeight: 128)?.height == 64)
    }

    /// 動く絵文字も、幅の上限のために低く読んだものは、高く描くときに読み直す。
    @Test func reloadsWideAnimationLimitedByAspectRatio() async throws {
        let store = makeStore(try Self.gif(width: 1_024, height: 64, frameCount: 2))
        _ = store.animation(for: url)
        try await waitUntil { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 48)

        _ = store.animation(for: url, pixelHeight: 128)
        try await waitUntil { store.upgradingAnimations.isEmpty }
        #expect(store.animation(for: url, pixelHeight: 128)?.image.frameHeight == 64)
    }
}
