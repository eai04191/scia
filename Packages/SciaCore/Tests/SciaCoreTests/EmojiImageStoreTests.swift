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

    /// 最初の`failures`回は503で失敗し、そのあとは`data`を返すストア。
    private func makeStore(_ data: Data, failingFirst failures: Int, clock: TestClock) -> EmojiImageStore<CGImage> {
        EmojiImageStore(
            clock: clock,
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { nil }
        ) { [fetches] _ in
            let count = fetches.count.withLock { count in
                count += 1
                return count
            }
            if count <= failures { throw HTTPStatusError(statusCode: 503) }
            return data
        }
    }

    /// 待ちが固まったときに失敗に添える、`url`のアニメーションの読み込みの状態。GIFを読むテストが、たまに読み終えないまま固まったため。
    private func animationState(of store: EmojiImageStore<CGImage>, _ url: URL) async -> String {
        [store.animationDiagnosis(of: url), await ImageDecoder.queueState(), "fetches: \(fetches.count.withLock { $0 })"].joined(separator: "\n")
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

    /// 読めなかった絵文字は、読み直してよくなった時刻に知らせ、まだ描いている画面が描き直して読み直す。描き直しを待たない。
    /// 描き直されない画面で、間隔が過ぎても`:shortcode:`のまま残らないため（docs/network.md）。
    @Test func asksToRedrawFailedStillWhenRetryIsAllowed() async throws {
        let clock = TestClock()
        let store = makeStore(try Self.png(width: 96, height: 96), failingFirst: 1, clock: clock)
        // 絵文字を描いている画面は、知らせを受けたら描き直し、描き直しで画像を求める。
        store.addListener(owner: clock) { [url] urls in
            if urls.contains(url) { _ = store.image(for: url) }
        }
        #expect(store.image(for: url) == nil)
        try await waitUntil { store.hasFailed(url) && clock.sleeperCount(remaining: .seconds(5)) >= 1 }
        clock.advance(by: .seconds(5))
        try await waitUntil { !store.hasFailed(url) && store.loading.isEmpty }
        #expect(store.image(for: url) != nil)
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 動く絵文字も、読めなかったら静止画で描き、読み直してよくなった時刻に知らせて、描いている画面に読み直させる。
    @Test func asksToRedrawFailedAnimationWhenRetryIsAllowed() async throws {
        let clock = TestClock()
        let store = makeStore(try Self.gif(size: 96, frameCount: 2), failingFirst: 1, clock: clock)
        store.addListener(owner: clock) { [url] urls in
            if urls.contains(url) { _ = store.animation(for: url) }
        }
        #expect(store.animation(for: url) == nil)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.hasFinishedLoadingAnimation(for: url) && clock.sleeperCount(remaining: .seconds(5)) >= 1 }
        clock.advance(by: .seconds(5))
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 取り消しのように失敗として覚えないものは、読み直してよくなった知らせを送らない。送ると、描き直した画面がすぐ読み、また取り消されて、待たずに繰り返すため。
    @Test func doesNotAskToRedrawAnimationAfterCancellation() async throws {
        let clock = TestClock()
        let other = URL(string: "https://example.com/other.gif")!
        let store = EmojiImageStore<CGImage>(
            clock: clock,
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { nil }
        ) { [fetches, url] requested in
            if requested == url {
                fetches.count.withLock { $0 += 1 }
                throw CancellationError()
            }
            throw HTTPStatusError(statusCode: 404)
        }
        store.addListener(owner: clock) { [url] urls in
            if urls.contains(url) { _ = store.animation(for: url) }
        }
        _ = store.animation(for: url)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: url) }
        // 知らせるなら、あとから求めた絵文字より先に読み直す。あとから求めた絵文字を読み終えるまで待ってから、読み直していないことを確かめる。
        _ = store.animation(for: other)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: other) }
        #expect(fetches.count.withLock { $0 } == 1)
        #expect(clock.sleeperCount == 0)
    }

    /// 知らせを受けても描き直す画面がなければ（画面から外れた、隠れているなど）、読み直さない。
    @Test func doesNotRetryFailedStillWithoutRedraw() async throws {
        let clock = TestClock()
        let store = makeStore(try Self.png(width: 96, height: 96), failingFirst: 1, clock: clock)
        var notified: [Set<URL>] = []
        store.addListener(owner: clock) { notified.append($0) }
        _ = store.image(for: url)
        // 読めなかったときにも1回知らせる。
        try await waitUntil { store.hasFailed(url) && clock.sleeperCount(remaining: .seconds(5)) >= 1 && notified.count >= 1 }
        #expect(notified.count == 1)
        clock.advance(by: .seconds(5))
        try await waitUntil { notified == [[url], [url]] }
        #expect(clock.sleeperCount == 0)
        #expect(store.loading.isEmpty)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    /// 読めた画像の、縮める前の元の幅と高さを渡す。カスタム絵文字のリストに縦横比を残すため。
    @Test func reportsSourceSizeOfLoadedStill() async throws {
        let store = makeStore(try Self.png(width: 400, height: 100))
        var sizes: [String] = []
        store.onSourceSize = { url, width, height in sizes.append("\(url.lastPathComponent) \(width)x\(height)") }
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        #expect(sizes == ["emoji.png 400x100"])
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
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 96)

        let previous = try #require(store.animation(for: url))
        #expect(store.animation(for: url, pixelHeight: 1_000) === previous, "読み直している間は、前のコマで動かす")
        try await waitUntil(state: { await animationState(of: store, url) }) { store.upgradingAnimations.isEmpty }
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
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 48)

        _ = store.animation(for: url, pixelHeight: 128)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.upgradingAnimations.isEmpty }
        #expect(store.animation(for: url, pixelHeight: 128)?.image.frameHeight == 64)
    }

    /// メモリ警告で手放すのは、使っていない絵文字だけ。描いているアニメーションは、手放したあとも読み直さずに同じものを返す。
    @Test func releasingUnusedMemoryKeepsDrawnAnimation() async throws {
        let store = makeStore(try Self.gif(size: 96, frameCount: 2))
        _ = store.animation(for: url)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        let drawn = try #require(store.animation(for: url))

        store.releaseUnusedMemory()

        #expect(store.animation(for: url) === drawn)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    /// 使っていない静止画は、メモリ警告で手放し、また描くときに読み直す。
    @Test func releasingUnusedMemoryDropsUnusedStill() async throws {
        let store = makeStore(try Self.png(width: 96, height: 96))
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }

        store.releaseUnusedMemory()

        #expect(store.image(for: url) == nil)
        try await waitUntil { store.image(for: url) != nil }
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 手放した静止画の高さは、メモリ警告のときに一緒に消す。通り過ぎて描き直さない絵文字の高さを、起動している間ずっと溜めないため。
    @Test func releasingUnusedMemoryForgetsResolutionsOfReleasedStills() async throws {
        let store = makeStore(try Self.png(width: 96, height: 96))
        let urls = try (0..<3).map { try #require(URL(string: "https://example.com/emoji\($0).png")) }
        for url in urls { _ = store.image(for: url) }
        try await waitUntil { urls.allSatisfy { store.image(for: $0) != nil } }
        #expect(store.stillResolutionCount == 3)

        store.releaseUnusedMemory()

        #expect(store.stillResolutionCount == 0)
    }
}
