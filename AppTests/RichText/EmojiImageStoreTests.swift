import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// 読めなかった絵文字は、起動し直すまで文字のままにせず、間隔をおいて読み直す。
@MainActor
struct EmojiImageStoreTests {
    private let clock = TestClock()
    private let url = URL(filePath: "/").appending(path: "emoji.png")

    /// 1回目は`first`で失敗し、2回目からは画像を返す。読んだ回数を数える。
    private final class Responses: Sendable {
        private let count = Mutex(0)
        let first: any Error & Sendable

        init(first: any Error & Sendable) {
            self.first = first
        }

        var fetchCount: Int { count.withLock { $0 } }

        func fetch(_: URL) throws -> Data {
            let isFirst = count.withLock { count in
                defer { count += 1 }
                return count == 0
            }
            if isFirst { throw first }
            return try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        }
    }

    private func makeStore(_ responses: Responses) -> EmojiImageStore {
        EmojiImageStore(clock: clock, retryPolicy: { ImageRetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { url in
            try responses.fetch(url)
        }
    }

    /// 通信の失敗やサーバーの一時的な障害で読めなかった絵文字は、間隔が過ぎてから描くと読み直し、読めたら画像で描く。
    /// 読み直している間も、文字で描き続ける。
    @Test(arguments: [URLError(.notConnectedToInternet) as any Error & Sendable, RemoteFetchError(statusCode: 503)])
    func temporaryFailureIsRetriedAfterTheDelay(error: any Error & Sendable) async throws {
        let responses = Responses(first: error)
        let store = makeStore(responses)

        #expect(store.image(for: url) == nil)
        try await waitUntil { store.hasFailed(url) }
        #expect(store.image(for: url) == nil)
        #expect(responses.fetchCount == 1, "間隔の前に読み直しました")

        clock.advance(by: .seconds(5))
        #expect(store.image(for: url) == nil)
        #expect(store.hasFailed(url), "読み直している間に文字で描かなくなりました")
        try await waitUntil { store.image(for: url) != nil }
        #expect(responses.fetchCount == 2)
        #expect(!store.hasFailed(url))
    }

    /// 消えた画像は、自動では読み直さない。使う人がメニューを開いたときは読み直す。
    @Test func missingImageIsRetriedOnlyWhenTheUserAsks() async throws {
        let responses = Responses(first: RemoteFetchError(statusCode: 404))
        let store = makeStore(responses)

        _ = store.image(for: url)
        try await waitUntil { store.hasFailed(url) }
        clock.advance(by: .seconds(3600))
        #expect(store.image(for: url) == nil)
        #expect(responses.fetchCount == 1)

        _ = store.image(for: url, retriesNow: true)
        try await waitUntil { store.image(for: url) != nil }
        #expect(responses.fetchCount == 2)
    }

    /// 静止画は、行の高さに合わせて描くので、横長でも高さを96pxにそろえて縮める。
    @Test(arguments: [(400, 100, 384, 96), (100, 400, 24, 96), (40, 20, 40, 20)])
    func stillImageIsShrunkToTheRowHeight(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData())
        let store = EmojiImageStore(clock: clock) { _ in png }

        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        let image = try #require(store.image(for: url)?.cgImage)
        #expect(image.width == expectedWidth)
        #expect(image.height == expectedHeight)
    }

    /// 同じサーバーの`/media_proxy`が429で止められている間は、まだ読んでいない絵文字も読まない。
    @Test func freshEmojiWaitsWhileTheProxyIsRateLimited() async throws {
        let limited = try #require(URL(string: "https://example.social/media_proxy/1/original"))
        let fresh = try #require(URL(string: "https://example.social/media_proxy/2/original"))
        let reads = Mutex<[URL]>([])
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let store = EmojiImageStore(clock: clock, retryPolicy: { ImageRetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { url in
            reads.withLock { $0.append(url) }
            if url == limited { throw RemoteFetchError(statusCode: 429, retryAfter: .seconds(120)) }
            return png
        }

        _ = store.image(for: limited)
        try await waitUntil { store.hasFailed(limited) }
        #expect(store.image(for: fresh) == nil)
        #expect(reads.withLock { $0 } == [limited])

        clock.advance(by: .seconds(120))
        _ = store.image(for: fresh)
        try await waitUntil { store.image(for: fresh) != nil }
        #expect(reads.withLock { $0 } == [limited, fresh])
    }
}
