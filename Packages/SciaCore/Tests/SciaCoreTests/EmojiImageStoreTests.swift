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

    /// - Parameters:
    ///   - upgradePurpose: 持っている画像より高く再読み込みする通信の目的。nilなら、再読み込みの通信を送れない回線として扱う。
    ///   - storedLocally: 端末に元の画像を置いているか。置いていれば、通信せずに`data`を返す。
    private func makeStore(_ data: Data, upgradePurpose: RequestPurpose? = .enhancement(onExpensiveNetwork: false), storedLocally: Bool = false) -> EmojiImageStore<CGImage> {
        EmojiImageStore(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { upgradePurpose },
            storedData: { _ in storedLocally ? data : nil }
        ) { [fetches] _ in
            fetches.count.withLock { $0 += 1 }
            return data
        }
    }

    /// プリフェッチで読めなかった画像は、表示の読み込みと同じく覚え、続けてプリフェッチしない。通信の失敗でなければ覚えない。
    @Test func remembersPrefetchFailures() {
        let store = makeStore(Data())
        let other = URL(string: "https://example.com/other.png")!
        #expect(store.allowsPrefetch(of: url))

        store.recordPrefetchFailure(HTTPStatusError(statusCode: 404), for: url)
        store.recordPrefetchFailure(CancellationError(), for: other)

        #expect(store.allowsPrefetch(of: url) == false)
        #expect(store.allowsPrefetch(of: other))
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
        [store.animationDiagnosis(of: url), ImageDecoder.queueState(), "fetches: \(fetches.count.withLock { $0 })"].joined(separator: "\n")
    }

    /// 1色で塗った`width`×`height`の画像。
    private static func image(width: Int, height: Int, gray: CGFloat = 0.5) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    static func png(width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width, height: height), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `frameCount`コマの、`size`四方のGIF。コマごとに明るさを変える。
    static func gif(size: Int, frameCount: Int) throws -> Data {
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

    /// 読めなかった絵文字は、再読み込みしてよくなった時刻に知らせ、まだ描いている画面が再描画して再読み込みする。再描画を待たない。
    /// 再描画されない画面で、間隔が過ぎても`:shortcode:`のまま残らないため（docs/network.md）。
    @Test func asksToRedrawFailedStillWhenRetryIsAllowed() async throws {
        let clock = TestClock()
        let store = makeStore(try Self.png(width: 96, height: 96), failingFirst: 1, clock: clock)
        // 絵文字を描いている画面は、通知を受けたら再描画し、再描画で画像を求める。
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

    /// 動く絵文字も、読めなかったら静止画で描き、再読み込みしてよくなった時刻に知らせて、描いている画面に再読み込みさせる。
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

    /// 取り消しのように失敗として覚えないものは、再読み込みしてよくなった通知を送らない。送ると、再描画した画面がすぐ読み、また取り消されて、待たずに繰り返すため。
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
        // 知らせるなら、あとから求めた絵文字より先に再読み込みする。あとから求めた絵文字を読み終えるまで待ってから、再読み込みしていないことを確かめる。
        _ = store.animation(for: other)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: other) }
        #expect(fetches.count.withLock { $0 } == 1)
        #expect(clock.sleeperCount == 0)
    }

    /// 通知を受けても再描画する画面がなければ（画面から外れた、隠れているなど）、再読み込みしない。
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

    /// 1コマしかない元の画像は、読み終えてから動かないと分かる。読む前には分からない。分かったら、知りたい側にだけ知らせる。
    @Test func knowsStillOnlyAfterLoadingOriginal() async throws {
        let store = makeStore(try Self.png(width: 40, height: 40))
        let owner = NSObject()
        var stills: [Set<URL>] = []
        store.addStillListener(owner: owner) { stills.append($0) }
        #expect(!store.isKnownStill(url))
        _ = store.animation(for: url)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: url) }
        #expect(store.isKnownStill(url))
        #expect(stills == [[url]])
    }

    /// 画像として読めないデータは、動くかが分からないので、動かないと分かったことにしない。
    @Test func unreadableOriginalIsNotKnownStill() async throws {
        let store = makeStore(Data("not an image".utf8))
        _ = store.animation(for: url)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: url) }
        #expect(!store.isKnownStill(url))
    }

    /// 読めた応答の出どころを数えて、状態ダンプに出す。捨てた画像の再読み込みが通信になっているかを、違和感レポートで見るため。
    @Test func countsWhereResponsesCameFrom() async throws {
        let data = try Self.png(width: 100, height: 100)
        let store = EmojiImageStore(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker<CGImage>(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { nil }
        ) { url in
            switch url.lastPathComponent {
            case "cached.png": ResponseSource.report?(.cache)
            case "stored.png": ResponseSource.report?(.file)
            case "fresh.png": ResponseSource.report?(.network)
            default: break
            }
            return data
        }
        let urls = ["cached.png", "stored.png", "fresh.png", "silent.png"].map { url.deletingLastPathComponent().appending(path: $0) }
        urls.forEach { _ = store.image(for: $0) }
        try await waitUntil { urls.allSatisfy { store.image(for: $0) != nil } }
        #expect(store.stateDump().contains("stillFetched: network 1 cache 1 file 1 unknown 1 shared 0 afterEviction: network 0 cache 0 file 0 unknown 0 shared 0"))
    }

    /// 同じURLの静止画とアニメーションを続けて求めたら、1回だけ読み、そのデータから両方を作る。動かす場所が、元の画像を2回読まないため。
    @Test func fetchesOnceForStillAndAnimationOfSameURL() async throws {
        let store = makeStore(try Self.gif(size: 100, frameCount: 3))

        _ = store.image(for: url)
        _ = store.animation(for: url)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.image(for: url) != nil && store.animation(for: url) != nil }

        #expect(fetches.count.withLock { $0 } == 1)
        #expect(store.stateDump().contains("animationFetched: network 0 cache 0 file 0 unknown 0 shared 1"))
    }

    /// 静止画とアニメーションで分け合った1回の通信が失敗したら、失敗は1回と数える。2回と数えると、1回の失敗で、再読み込みするまでの間隔が2回失敗したときの長さになる。
    @Test func countsFailureOfSharedFetchOnce() async throws {
        let clock = TestClock()
        let store = makeStore(try Self.gif(size: 96, frameCount: 2), failingFirst: 1, clock: clock)
        store.addListener(owner: clock) { [url] urls in
            if urls.contains(url) { _ = store.image(for: url) }
        }

        _ = store.image(for: url)
        _ = store.animation(for: url)
        try await waitUntil(state: { await animationState(of: store, url) }) {
            store.hasFailed(url) && store.hasFinishedLoadingAnimation(for: url) && clock.sleeperCount(remaining: .seconds(5)) >= 1
        }
        #expect(fetches.count.withLock { $0 } == 1)
        clock.advance(by: .seconds(5))

        try await waitUntil { store.image(for: url) != nil }
    }

    /// 大きすぎて動かせない元の画像は、最初のコマを静止画で描き、大きさを残して、端末に置いたファイルを消させる。
    /// 次からは、動かす場所も動かない版を選び、元の画像のアニメーションを求めても読まない。
    @Test(.scratch) func recordsOversizedOriginalAndStopsReadingIt() async throws {
        let record = OversizedEmojiRecord(file: TestScratch.url("EmojiImageStoreTests").appending(path: "oversized.json"))
        let store = makeStore(try Self.gif(width: 1_100, height: 1_000, frameCount: 2))
        store.oversized = record
        let discarded = Mutex<[URL]>([])
        store.onDiscard = { url in discarded.withLock { $0.append(url) } }
        let emoji = CustomEmoji(shortcode: "big", url: url, staticUrl: url.deletingLastPathComponent().appending(path: "static.png"))
        #expect(store.choice(animates: true).url(of: emoji) == emoji.url)

        _ = store.image(for: url)
        _ = store.animation(for: url)
        // 大きさを残したあと、端末のファイルを消させ終えてから、読み込みの状態を片付ける。片付け終えるまで待つ。
        try await waitUntil(state: { await animationState(of: store, url) }) {
            record.contains(url) && store.animationDiagnosis(of: url).contains("animationState: nil") && store.image(for: url) != nil
        }

        // 静止画が、大きさを残したあとに読み終えたら、静止画の側からも消させる。何度消させても同じ。
        #expect(Set(discarded.withLock { $0 }) == [url])
        #expect(record.contains(url))
        #expect(store.choice(animates: true).url(of: emoji) == emoji.url, "この起動の間は、読めている元の画像の最初のコマで描き続ける")
        let fetched = fetches.count.withLock { $0 }
        #expect(store.animation(for: url) == nil)
        #expect(store.animationDiagnosis(of: url).contains("animationState: nil"), "アニメーションは読み直さない")
        #expect(fetches.count.withLock { $0 } == fetched)

        // 起動し直したあと。
        let next = makeStore(try Self.gif(width: 1_100, height: 1_000, frameCount: 2))
        next.oversized = OversizedEmojiRecord(file: record.file)
        #expect(next.choice(animates: true).url(of: emoji) == emoji.staticUrl)
        #expect(next.choice(animates: true).animationURL(of: emoji) == nil)
        #expect(next.animation(for: url) == nil)
        #expect(next.animationDiagnosis(of: url).contains("animationState: nil"), "読み始めない")
    }

    /// 大きすぎて動かせないと分かった元の画像の静止画を、メモリから捨てたあとに再読み込みしたときも、端末に置いたファイルを消させる。
    @Test(.scratch) func discardsOversizedOriginalWhenStillIsReloaded() async throws {
        let record = OversizedEmojiRecord(file: TestScratch.url("EmojiImageStoreTests").appending(path: "reloaded.json"))
        record.record(url, width: 1_100, height: 1_000, frameCount: 2)
        let store = makeStore(try Self.gif(width: 1_100, height: 1_000, frameCount: 2))
        store.oversized = record
        let discarded = Mutex<[URL]>([])
        store.onDiscard = { url in discarded.withLock { $0.append(url) } }

        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }

        #expect(discarded.withLock { $0 } == [url])
    }

    /// 1コマしかない元の画像は、大きすぎるのではないので残さず、端末に置いたファイルも消させない。動かす場所が、次も同じ元の画像を端末から読むため。
    @Test(.scratch) func doesNotRecordSingleFrameOriginal() async throws {
        let record = OversizedEmojiRecord(file: TestScratch.url("EmojiImageStoreTests").appending(path: "single.json"))
        let store = makeStore(try Self.png(width: 100, height: 100))
        store.oversized = record
        let discarded = Mutex<[URL]>([])
        store.onDiscard = { url in discarded.withLock { $0.append(url) } }

        _ = store.animation(for: url)
        try await waitUntil { store.hasFinishedLoadingAnimation(for: url) }

        #expect(!record.contains(url))
        #expect(discarded.withLock { $0 }.isEmpty)
    }

    /// 読んだデータが画像として読めなかったら、URLを渡す。端末に置いたファイルを消して、次は取得し直せるようにするため。
    @Test func reportsUnreadableData() async throws {
        let store = makeStore(Data("not an image".utf8))
        let unreadable = Mutex<[URL]>([])
        store.onDiscard = { url in unreadable.withLock { $0.append(url) } }

        _ = store.image(for: url)
        try await waitUntil { store.hasFailed(url) }

        #expect(unreadable.withLock { $0 } == [url])
    }

    /// アニメーション版として読んだデータが画像として読めなかったときも、URLを渡す。1コマしかない画像は、読めているので渡さない。
    @Test func reportsUnreadableAnimationDataButNotStillImages() async throws {
        let still = try Self.png(width: 100, height: 100)
        let store = EmojiImageStore(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker<CGImage>(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { nil }
        ) { url in
            url.lastPathComponent == "broken.gif" ? Data("not an image".utf8) : still
        }
        let unreadable = Mutex<[URL]>([])
        store.onDiscard = { url in unreadable.withLock { $0.append(url) } }
        let urls = ["broken.gif", "still.png"].map { url.deletingLastPathComponent().appending(path: $0) }

        urls.forEach { _ = store.animation(for: $0) }
        try await waitUntil { urls.allSatisfy { store.hasFinishedLoadingAnimation(for: $0) } }

        #expect(unreadable.withLock { $0 } == [urls[0]])
    }

    /// 既定より大きく描くと、そのURLを描く高さで再読み込みする。読み終えるまでは前の画像を返し、読み終えたら、小さく描く場所にも同じ1枚を返す。
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

    private final class Owner {}

    /// 持ち主を渡して高さを上げて再読み込みしたときは、読み終えたことをその持ち主の通知先にだけ知らせる。前の画像で描けているほかの画面を再描画させないため。
    @Test func notifiesOnlyRequesterOfUpgrade() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400))
        let requester = Owner()
        let other = Owner()
        var requesterNotified: [Set<URL>] = []
        var otherNotified: [Set<URL>] = []
        store.addListener(owner: requester) { requesterNotified.append($0) }
        store.addListener(owner: other) { otherNotified.append($0) }
        _ = store.image(for: url, requester: requester)
        try await waitUntil { requesterNotified.count >= 1 }
        #expect(otherNotified == [[url]], "初めて読んだ画像は、待っているほかの画面にも知らせる")

        #expect(store.image(for: url, pixelHeight: 200, requester: requester)?.height == 96)
        try await waitUntil { requesterNotified.count >= 2 }
        #expect(requesterNotified.last == [url])
        #expect(store.image(for: url, pixelHeight: 200)?.height == 200)
        #expect(otherNotified == [[url]], "前の画像で描けているほかの画面には知らせない")
    }

    /// 持ち主を渡して高く再読み込みしている間に前の画像がメモリから捨てられ、ほかの画面が求めて画像を得られなかったら、その画面にも読み終えたことを知らせる。
    @Test func notifiesDrawerThatMissedEvictedImageDuringUpgrade() async throws {
        let png = try Self.png(width: 400, height: 400)
        let gate = Gate()
        let calls = Mutex(0)
        let store = EmojiImageStore<CGImage>(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { .enhancement(onExpensiveNetwork: false) }
        ) { _ in
            if calls.withLock({ $0 += 1; return $0 }) > 1 { try await gate.wait() }
            return png
        }
        let requester = Owner()
        let other = Owner()
        var otherNotified: [Set<URL>] = []
        store.addListener(owner: requester) { _ in }
        store.addListener(owner: other) { otherNotified.append($0) }
        _ = store.image(for: url)
        try await waitUntil { otherNotified.count >= 1 }

        _ = store.image(for: url, pixelHeight: 200, requester: requester)
        store.releaseUnusedMemory()
        #expect(store.image(for: url) == nil, "前の画像は捨てられている")
        gate.open()
        try await waitUntil { otherNotified.count >= 2 }
    }

    /// 持ち主を渡さずに同じURLを高く求めた描く側がいれば、誰が待っているか分からないので、すべての通知先に知らせる。
    @Test func notifiesEveryoneWhenUnknownDrawerAlsoWaitsForUpgrade() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400))
        let requester = Owner()
        let other = Owner()
        var otherNotified: [Set<URL>] = []
        store.addListener(owner: requester) { _ in }
        store.addListener(owner: other) { otherNotified.append($0) }
        _ = store.image(for: url)
        try await waitUntil { otherNotified.count >= 1 }

        _ = store.image(for: url, pixelHeight: 200, requester: requester)
        _ = store.image(for: url, pixelHeight: 200)
        try await waitUntil { otherNotified.count >= 2 }
        #expect(store.image(for: url)?.height == 200)
    }

    /// 動く絵文字を持ち主を渡して高く再読み込みしたときも、その持ち主の通知先にだけ知らせる。
    @Test func notifiesOnlyRequesterOfAnimationUpgrade() async throws {
        let store = makeStore(try Self.gif(size: 512, frameCount: 4))
        let requester = Owner()
        let other = Owner()
        var requesterNotified: [Set<URL>] = []
        var otherNotified: [Set<URL>] = []
        store.addListener(owner: requester) { requesterNotified.append($0) }
        store.addListener(owner: other) { otherNotified.append($0) }
        _ = store.animation(for: url, requester: requester)
        try await waitUntil(state: { await animationState(of: store, url) }) { requesterNotified.count >= 1 }
        #expect(otherNotified.count == 1)

        _ = store.animation(for: url, pixelHeight: 200, requester: requester)
        try await waitUntil(state: { await animationState(of: store, url) }) { requesterNotified.count >= 2 }
        #expect(store.animation(for: url, pixelHeight: 200)?.image.frameHeight == 200)
        #expect(otherNotified.count == 1, "前のコマで動かせているほかの画面には知らせない")
    }

    /// 元の画像が求めた高さより小さければ、元の大きさで読み、それより高く描くことになっても再読み込みしない。拡大しても、ぼけは消えないため。
    @Test func doesNotReloadBeyondSourceSize() async throws {
        let store = makeStore(try Self.png(width: 128, height: 128))
        _ = store.image(for: url, pixelHeight: 300)
        try await waitUntil { store.loading.isEmpty && store.image(for: url, pixelHeight: 300) != nil }
        #expect(store.image(for: url, pixelHeight: 300)?.height == 128)

        _ = store.image(for: url, pixelHeight: 600)
        #expect(store.loading.isEmpty)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    /// 動く絵文字を大きく描くと再読み込みし、その高さでは`AnimatedImage.maxByteCount`を超えるなら、動きを止めずに、収まる中で一番高く読む。
    /// それより高く描くことになっても、同じ上限に当たるので再読み込みしない。
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

    /// 再読み込みの通信を送れない回線で、端末に元の画像もなければ、持っている画像より高く再読み込みせず、持っている画像を拡大して描く。
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

    /// 端末に元の画像があれば、再読み込みの通信を送れない回線（低データモード）でも、通信せずに端末の画像から描く高さで作り直す。
    @Test func reloadsFromStoredDataWithoutUpgradePurpose() async throws {
        let store = makeStore(try Self.png(width: 400, height: 400), upgradePurpose: nil, storedLocally: true)
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        let fetchesBefore = fetches.count.withLock { $0 }

        _ = store.image(for: url, pixelHeight: 200)
        try await waitUntil { store.image(for: url, pixelHeight: 200)?.height == 200 }

        #expect(fetches.count.withLock { $0 } == fetchesBefore)
    }

    /// 持っている画像の1.1倍（`upscaleTolerance`）までの高さなら、再読み込みせずに拡大して描く。初めて読むときも、既定の高さの1.1倍までなら既定の高さで読む。
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

    /// とても大きく描くときも、静止画1枚は`maxStillPixelCount`に収まる高さで止める。1枚でキャッシュの上限を超えると、入れたそばから捨てられて再読み込みし続けるため。
    /// 止めたら、それより高く描くことになっても再読み込みしない。
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

    /// 極端に横長な画像は、幅の上限のために求めた高さより低く読むが、元の画像には余裕があるので、高く描くときは再読み込みする。
    @Test func reloadsWideStillLimitedByAspectRatio() async throws {
        let store = makeStore(try Self.png(width: 2_048, height: 128))
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        #expect(store.image(for: url)?.height == 48, "幅は高さの8倍の768pxで止めるので、高さは48px")

        _ = store.image(for: url, pixelHeight: 128)
        try await waitUntil { store.loading.isEmpty }
        #expect(store.image(for: url, pixelHeight: 128)?.height == 64)
    }

    /// 動く絵文字も、幅の上限のために低く読んだものは、高く描くときに再読み込みする。
    @Test func reloadsWideAnimationLimitedByAspectRatio() async throws {
        let store = makeStore(try Self.gif(width: 1_024, height: 64, frameCount: 2))
        _ = store.animation(for: url)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 48)

        _ = store.animation(for: url, pixelHeight: 128)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.upgradingAnimations.isEmpty }
        #expect(store.animation(for: url, pixelHeight: 128)?.image.frameHeight == 64)
    }

    /// メモリ警告で手放すのは、使っていない絵文字だけ。描いているアニメーションは、手放したあとも再読み込みせずに同じものを返す。
    @Test func releasingUnusedMemoryKeepsDrawnAnimation() async throws {
        let store = makeStore(try Self.gif(size: 96, frameCount: 2))
        _ = store.animation(for: url)
        try await waitUntil(state: { await animationState(of: store, url) }) { store.animation(for: url) != nil }
        let drawn = try #require(store.animation(for: url))

        store.releaseUnusedMemory()

        #expect(store.animation(for: url) === drawn)
        #expect(fetches.count.withLock { $0 } == 1)
    }

    /// 使っていない静止画は、メモリ警告で手放し、また描くときに再読み込みする。
    @Test func releasingUnusedMemoryDropsUnusedStill() async throws {
        let store = makeStore(try Self.png(width: 96, height: 96))
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }

        store.releaseUnusedMemory()

        #expect(store.image(for: url) == nil)
        try await waitUntil { store.image(for: url) != nil }
        #expect(fetches.count.withLock { $0 } == 2)
    }

    /// 手放した静止画の高さは、メモリ警告のときに一緒に消す。通り過ぎて再描画しない絵文字の高さを、起動している間ずっと溜めないため。
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
