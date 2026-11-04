import CoreGraphics
import Foundation
import ImageIO
import SciaTesting
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

/// 画面に描いている画像が読めなかったとき、描き直されなくても、読み直してよくなった時刻に読み直す（docs/image-loading.md）。
@MainActor
@Suite(.scratch)
struct ShownImageRetryTests {
    private let clock = TestClock()
    private let fetcher = Fetcher()
    private let root = TestScratch.url("ShownImageRetryTests")

    /// URLごとに、決めた順に失敗か画像を返す。決めた分を使い切ったら画像を返す。
    private final class Fetcher: Sendable {
        private let state = Mutex<(planned: [URL: [any Error]], fetched: [URL])>(([:], []))

        func fail(_ url: URL, with errors: any Error...) {
            state.withLock { $0.planned[url, default: []] += errors }
        }

        func count(of url: URL) -> Int {
            state.withLock { $0.fetched.filter { $0 == url }.count }
        }

        func fetch(_ url: URL) throws -> Data {
            let error = state.withLock { state -> (any Error)? in
                state.fetched.append(url)
                return state.planned[url]?.isEmpty == false ? state.planned[url]?.removeFirst() : nil
            }
            if let error {
                throw error
            }
            return try ShownImageRetryTests.png()
        }
    }

    private nonisolated static func png() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor private final class Flag {
        var value = true
    }

    private static let policy = RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60), hiddenRecheckInterval: .seconds(1))
    private static let maker = PlatformImageMaker<CGImage>(still: { $0 }, animated: { _, _ in nil })

    private func makeMediaStore() -> MediaImageStore<CGImage> {
        let fetcher = fetcher
        return MediaImageStore(
            files: MediaFileCache(directory: root.appending(path: "files"), sharingDirectory: root.appending(path: "sharing"), sizeLimit: 1_024 * 1_024) { Date(timeIntervalSince1970: 0) },
            prefetchedFiles: nil,
            clock: clock,
            retryPolicy: { Self.policy },
            maker: Self.maker
        ) { url, _ in try fetcher.fetch(url) }
    }

    private func makeAvatarStore() -> AvatarImageStore<CGImage> {
        let fetcher = fetcher
        return AvatarImageStore(clock: clock, retryPolicy: { Self.policy }, maker: Self.maker) { url in try fetcher.fetch(url) }
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private func thumbnail(_ url: URL) -> MediaThumbnailRequest {
        MediaThumbnailRequest(url: url, maxPixelSize: 64, purpose: .display)
    }

    /// 待てば直る失敗は、描き直されなくても、間隔が過ぎたら読み直して画像を返す。
    @Test func thumbnailIsReloadedWhenTheDelayPasses() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/small")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 503))

        let load = Task { await store.shownThumbnail(for: thumbnail(image), while: { true }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(fetcher.count(of: image) == 1)
        clock.advance(by: .seconds(5))

        #expect(await load.value != nil)
        #expect(fetcher.count(of: image) == 2)
    }

    /// `/media_proxy`が429で止まっている間に描いたサムネイルは、止まっている間は読まず、明けたら読む。
    @Test func thumbnailDeferredByRateLimitIsLoadedWhenTheLimitEnds() async throws {
        let store = makeMediaStore()
        let limited = try url("https://example.social/media_proxy/1/small")
        let waiting = try url("https://example.social/media_proxy/2/small")
        fetcher.fail(limited, with: HTTPStatusError(statusCode: 429, retryAfter: .seconds(600)))
        _ = try? await store.thumbnail(for: thumbnail(limited))

        let load = Task { await store.shownThumbnail(for: thumbnail(waiting), while: { true }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(fetcher.count(of: waiting) == 0, "止まっている間は読まない")
        clock.advance(by: .seconds(599))
        #expect(fetcher.count(of: waiting) == 0)
        clock.advance(by: .seconds(1))

        #expect(await load.value != nil)
        #expect(fetcher.count(of: waiting) == 1)
    }

    /// 待っても直らない失敗は、待たずにやめる。
    @Test func permanentFailureIsNotRetried() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/system/cache/media_attachments/1.png")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 404))

        #expect(await store.shownThumbnail(for: thumbnail(image), while: { true }, visible: { true }) == nil)
        #expect(clock.sleeperCount == 0)
        #expect(fetcher.count(of: image) == 1)
    }

    /// 待っている間に描く画像が替わったら、読み直さずにやめる。
    @Test func stopsWhenNoLongerWanted() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/small")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 503))
        let shown = Flag()

        let load = Task { await store.shownThumbnail(for: thumbnail(image), while: { shown.value }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        shown.value = false
        clock.advance(by: .seconds(5))

        #expect(await load.value == nil)
        #expect(fetcher.count(of: image) == 1)
    }

    /// 取り消したら、待つのをやめる。
    @Test func stopsWhenCancelled() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/small")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 503))

        let load = Task { await store.shownThumbnail(for: thumbnail(image), while: { true }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        load.cancel()

        #expect(await load.value == nil)
        #expect(clock.sleeperCount == 0)
        #expect(fetcher.count(of: image) == 1)
    }

    /// 添付ファイルの画像（リンクのカード、ヘッダー画像など）も、間隔が過ぎたら読み直す。
    @Test func mediaImageIsReloadedWhenTheDelayPasses() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/original")
        fetcher.fail(image, with: URLError(.timedOut))

        let load = Task { await store.shownImage(for: image, maxPixelSize: 64, while: { true }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(5))

        #expect(await load.value != nil)
        #expect(fetcher.count(of: image) == 2)
    }

    /// アイコンも、間隔が過ぎたら読み直す。
    @Test func avatarIsReloadedWhenTheDelayPasses() async throws {
        let store = makeAvatarStore()
        let key = AvatarImageKey(url: try url("https://example.social/media_proxy/1/original"), maxPixelSize: 64, animates: false)
        fetcher.fail(key.url, with: HTTPStatusError(statusCode: 502), HTTPStatusError(statusCode: 502))

        let load = Task { await store.shownImage(for: key, while: { true }, visible: { true }) }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(5))
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(fetcher.count(of: key.url) == 2)
        clock.advance(by: .seconds(10))

        #expect(await load.value != nil)
        #expect(fetcher.count(of: key.url) == 3)
    }

    /// 最初の1回は隠れていても読み、読み直しは見えるまで待つ。見えたら、次に確かめたときに読む。
    @Test func retriesOnlyWhileVisible() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/small")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 503))
        let visible = Flag()
        visible.value = false

        let load = Task { await store.shownThumbnail(for: thumbnail(image), while: { true }, visible: { visible.value }) }
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(fetcher.count(of: image) == 1, "最初の1回は隠れていても読む")
        clock.advance(by: .seconds(5))
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(30))
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(fetcher.count(of: image) == 1, "隠れている間は読み直さない")

        visible.value = true
        clock.advance(by: .seconds(1))
        #expect(await load.value != nil)
        #expect(fetcher.count(of: image) == 2)
    }

    /// 同じ画像を待ち合わせた行も、読み直しをやめずに待つ。待ち合わせた側が、失敗を覚える前に結果を受け取らないため。
    @Test func coalescedLoadsAllRetry() async throws {
        let store = makeMediaStore()
        let image = try url("https://example.social/media_proxy/1/small")
        fetcher.fail(image, with: HTTPStatusError(statusCode: 503))

        let loads = (0..<5).map { _ in Task { await store.shownThumbnail(for: thumbnail(image), while: { true }, visible: { true }) } }
        try await waitUntil { clock.sleeperCount == loads.count }
        #expect(fetcher.count(of: image) == 1)
        clock.advance(by: .seconds(5))

        for load in loads {
            #expect(await load.value != nil)
        }
    }

    /// アイコンも、待ち合わせた行が読み直しをやめずに待つ。
    @Test func coalescedAvatarLoadsAllRetry() async throws {
        let store = makeAvatarStore()
        let key = AvatarImageKey(url: try url("https://example.social/media_proxy/1/original"), maxPixelSize: 64, animates: false)
        fetcher.fail(key.url, with: HTTPStatusError(statusCode: 503))

        let loads = (0..<5).map { _ in Task { await store.shownImage(for: key, while: { true }, visible: { true }) } }
        try await waitUntil { clock.sleeperCount == loads.count }
        clock.advance(by: .seconds(5))

        for load in loads {
            #expect(await load.value != nil)
        }
    }
}
